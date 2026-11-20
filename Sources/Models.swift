import Foundation
import AppKit

// MARK: - Data

struct WorkSession: Codable, Hashable {
    var start: Date
    var end: Date
}

/// A project that's currently open. `lastBeat` is updated every minute so time
/// isn't counted while the Mac is asleep or after the app quits unexpectedly.
struct ActiveSession: Codable, Hashable {
    var start: Date
    var lastBeat: Date
}

/// One window's saved position (screen points, top-left origin).
/// kind: "file", "app", "brave" or "claude". key: file path, app path or Brave window name.
struct SavedFrame: Codable, Hashable {
    var kind: String
    var key: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(kind: String, key: String, rect: CGRect) {
        self.kind = kind
        self.key = key
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        w = Double(rect.size.width)
        h = Double(rect.size.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Project"
    /// The project this one sits under in the tree (e.g. "Radiation" for "Assignment 1"). nil = top level.
    var parentID: UUID? = nil
    /// Absolute paths (may start with ~). Each opens in its default app. May include .app bundles.
    var files: [String] = []
    /// Web pages to open in Brave if the named window doesn't exist yet.
    var urls: [String] = []
    /// Name you gave the Brave window (Window > Name Window...). Restored on open, minimised on close.
    var braveWindowName: String = ""
    /// Apps in `files` that should be hidden (not quit) when the project closes.
    var hideAppsOnClose: [String] = []
    /// A claude.ai chat or project link, opened in the Claude desktop app.
    var claudeLink: String = ""
    /// What happens to the Claude app when the project closes: "quit", "hide" or "leave".
    var claudeOnClose: String = "hide"
    /// Optional due date, shown as a countdown in the menu.
    var deadline: Date? = nil
    /// Saved window positions, one layout per screen setup (see ScreenSetup).
    var layouts: [String: [SavedFrame]] = [:]
    /// Finished work sessions.
    var timeLog: [WorkSession] = []
    /// Set while the project is open.
    var activeSession: ActiveSession? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, parentID, files, urls, braveWindowName, hideAppsOnClose, claudeLink, claudeOnClose
        case deadline, layouts, timeLog, activeSession
    }
}

extension Project {
    /// Tolerant decoding, so projects saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Project"
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        braveWindowName = try c.decodeIfPresent(String.self, forKey: .braveWindowName) ?? ""
        hideAppsOnClose = try c.decodeIfPresent([String].self, forKey: .hideAppsOnClose) ?? []
        claudeLink = try c.decodeIfPresent(String.self, forKey: .claudeLink) ?? ""
        claudeOnClose = try c.decodeIfPresent(String.self, forKey: .claudeOnClose) ?? "hide"
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        layouts = try c.decodeIfPresent([String: [SavedFrame]].self, forKey: .layouts) ?? [:]
        timeLog = try c.decodeIfPresent([WorkSession].self, forKey: .timeLog) ?? []
        activeSession = try c.decodeIfPresent(ActiveSession.self, forKey: .activeSession)
    }

    /// Whether opening this project does anything (a parent can be just a group).
    var hasContent: Bool {
        !files.isEmpty || !urls.isEmpty || !braveWindowName.isEmpty || !claudeLink.isEmpty
    }

    /// Time spent with the project open, optionally only counting from `since`.
    func timeSpent(since: Date? = nil, now: Date = Date()) -> TimeInterval {
        var sessions = timeLog
        if let a = activeSession { sessions.append(WorkSession(start: a.start, end: now)) }
        var total: TimeInterval = 0
        for s in sessions {
            let start = since.map { max($0, s.start) } ?? s.start
            total += max(0, s.end.timeIntervalSince(start))
        }
        return total
    }
}

// MARK: - Store

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] {
        didSet { save() }
    }
    /// Which projects are currently "open" (ticked).
    @Published private(set) var openIDs: Set<UUID> = []
    /// Which project the editor window shows.
    @Published var editorSelection: UUID?

    private let fileURL: URL
    private var timer: Timer?

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("projects.json")
        load()
        finishStaleSessions()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
    }

    // MARK: Open / close

    func isOpen(_ p: Project) -> Bool { openIDs.contains(p.id) }

    func toggle(_ p: Project) {
        // Use the latest saved version, not the copy the menu was drawn with.
        guard let current = projects.first(where: { $0.id == p.id }) else { return }
        if isOpen(current) { close(current) } else { open(current) }
    }

    func open(_ p: Project) {
        Launcher.open(p)
        openIDs.insert(p.id)
        let now = Date()
        update(p.id) { $0.activeSession = ActiveSession(start: now, lastBeat: now) }
    }

    func close(_ p: Project) {
        Launcher.close(p)
        openIDs.remove(p.id)
        endSession(p.id)
    }

    func closeAll() {
        for p in projects where isOpen(p) { close(p) }
    }

    /// Called from the Quit menu item so the last few minutes are logged.
    func prepareToQuit() {
        for id in openIDs { endSession(id) }
    }

    // MARK: Time tracking

    private func endSession(_ id: UUID, at end: Date = Date()) {
        update(id) { p in
            guard let a = p.activeSession else { return }
            if end.timeIntervalSince(a.start) >= 30 {
                p.timeLog.append(WorkSession(start: a.start, end: end))
            }
            p.activeSession = nil
        }
    }

    /// Runs every minute. A gap of more than 3 minutes means the Mac was asleep:
    /// log up to the last beat and start a fresh session from now.
    func heartbeat() {
        let now = Date()
        var copy = projects
        var changed = false
        for i in copy.indices {
            guard var a = copy[i].activeSession else { continue }
            if now.timeIntervalSince(a.lastBeat) > 180 {
                if a.lastBeat.timeIntervalSince(a.start) >= 30 {
                    copy[i].timeLog.append(WorkSession(start: a.start, end: a.lastBeat))
                }
                a = ActiveSession(start: now, lastBeat: now)
            } else {
                a.lastBeat = now
            }
            copy[i].activeSession = a
            changed = true
        }
        if changed {
            projects = copy
        } else {
            objectWillChange.send() // keeps deadline countdowns in the menu fresh
        }
    }

    /// Sessions left over from a previous run (e.g. the app was quit by an update or a restart).
    private func finishStaleSessions() {
        var copy = projects
        var changed = false
        for i in copy.indices {
            guard let a = copy[i].activeSession else { continue }
            if a.lastBeat.timeIntervalSince(a.start) >= 30 {
                copy[i].timeLog.append(WorkSession(start: a.start, end: a.lastBeat))
            }
            copy[i].activeSession = nil
            changed = true
        }
        if changed { projects = copy }
    }

    // MARK: Layouts and capture

    func saveLayoutsForOpenProjects() {
        let key = ScreenSetup.currentKey()
        var lines: [String] = []
        for p in projects where openIDs.contains(p.id) {
            let frames = Layouts.capture(p)
            if frames.isEmpty {
                lines.append("\(p.name): no windows found")
                continue
            }
            update(p.id) { $0.layouts[key] = frames }
            lines.append("\(p.name): \(frames.count) window\(frames.count == 1 ? "" : "s")")
        }
        Alerts.show("Layout saved for this screen setup",
                    "Screens: \(key)\n\n" + lines.joined(separator: "\n")
                    + "\n\nNext time you open these projects with the same screens, the windows go back to these positions.")
    }

    func captureNewProject() {
        var p = Capture.currentProject()
        if p.files.isEmpty && p.braveWindowName.isEmpty && p.claudeLink.isEmpty {
            Alerts.show("Nothing to capture",
                        "Open the files, Brave window and Claude chat you want first, then try again. Project Launcher also needs Accessibility permission (System Settings > Privacy & Security > Accessibility) to see your open windows.")
            return
        }
        let frames = Layouts.capture(p)
        if !frames.isEmpty { p.layouts[ScreenSetup.currentKey()] = frames }
        let now = Date()
        p.activeSession = ActiveSession(start: now, lastBeat: now)
        projects.append(p)
        openIDs.insert(p.id)
        editorSelection = p.id
        EditorWindow.shared.show(store: self)
    }

    // MARK: Tree

    /// Direct sub-projects of `id`, in list order. nil gives the top level
    /// (including any whose parent no longer exists).
    func children(of id: UUID?) -> [Project] {
        guard let id else {
            let ids = Set(projects.map(\.id))
            return projects.filter { p in
                guard let parent = p.parentID else { return true }
                return parent == p.id || !ids.contains(parent)
            }
        }
        return projects.filter { $0.parentID == id && $0.id != id }
    }

    /// All sub-projects below `id`, at any depth.
    func descendants(of id: UUID) -> [Project] {
        var result: [Project] = []
        var seen: Set<UUID> = [id]
        var queue = [id]
        while !queue.isEmpty {
            for c in children(of: queue.removeFirst()) where seen.insert(c.id).inserted {
                result.append(c)
                queue.append(c.id)
            }
        }
        return result
    }

    /// Every project in tree order with its depth, for indented lists.
    func flattened() -> [(project: Project, depth: Int)] {
        var result: [(Project, Int)] = []
        var seen: Set<UUID> = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for p in children(of: parent) where seen.insert(p.id).inserted {
                result.append((p, depth))
                walk(p.id, depth + 1)
            }
        }
        walk(nil, 0)
        return result
    }

    /// e.g. "Radiation › Assignment 1"
    func path(of p: Project) -> String {
        var names = [p.name]
        var seen: Set<UUID> = [p.id]
        var current = p.parentID
        while let id = current, seen.insert(id).inserted,
              let parent = projects.first(where: { $0.id == id }) {
            names.insert(parent.name, at: 0)
            current = parent.parentID
        }
        return names.joined(separator: " › ")
    }

    // MARK: Editing

    func addProject(parent: UUID? = nil) -> UUID {
        var p = Project(name: parent == nil ? "New Project" : "New Sub-project")
        p.parentID = parent
        projects.append(p)
        return p.id
    }

    /// Sub-projects of a deleted project move up a level rather than being deleted.
    func delete(id: UUID) {
        let parent = projects.first(where: { $0.id == id })?.parentID
        var copy = projects
        copy.removeAll { $0.id == id }
        for i in copy.indices where copy[i].parentID == id { copy[i].parentID = parent }
        projects = copy
        openIDs.remove(id)
    }

    private func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
    }

    // MARK: Persistence (~/Library/Application Support/ProjectLauncher/projects.json)

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Helpers

func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

func isApp(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "app"
}

func formatDuration(_ t: TimeInterval) -> String {
    let mins = Int(t / 60)
    if mins < 60 { return "\(mins)m" }
    return "\(mins / 60)h \(mins % 60)m"
}

/// "3 days left", "due tomorrow", "due today", "2 days overdue".
func deadlineText(_ deadline: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: deadline)).day ?? 0
    if days < -1 { return "\(-days) days overdue" }
    if days == -1 { return "1 day overdue" }
    if days == 0 { return "due today" }
    if days == 1 { return "due tomorrow" }
    return "\(days) days left"
}
