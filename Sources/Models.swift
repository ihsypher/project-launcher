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
    /// Which of an app's windows this is: its title when saved, and for Terminal its tty.
    var title: String? = nil
    var tty: String? = nil

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

/// A named set of projects. Only a name: time is totalled from its projects.
struct ProjectGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Group"
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = "New Project"
    /// The group this project is in (e.g. "Radiation"). nil = not in a group.
    var groupID: UUID? = nil
    /// Sub-project parent from versions 1.2 to 1.12, only read to convert to groups.
    var legacyParentID: UUID? = nil
    /// Absolute paths (may start with ~). Each opens in its default app. May include .app bundles.
    var files: [String] = []
    /// Web pages to open in Brave if the named window doesn't exist yet.
    var urls: [String] = []
    /// Names you gave Brave windows (Window > Name Window...). Restored on open, minimised on close.
    var braveWindowNames: [String] = []
    /// SF Symbol shown for the project in the menu and editor.
    var icon: String = "doc.text"
    /// One of ProjectColor's names.
    var color: String = "blue"
    /// Apps in `files` that should be hidden (not quit) when the project closes.
    var hideAppsOnClose: [String] = []
    /// Apps in `files` whose project window should be minimised (not the app hidden or quit)
    /// when the project closes. Takes priority over hiding.
    var minimiseAppsOnClose: [String] = []
    /// Word/Excel/PowerPoint files whose app should be quit (not just the file closed)
    /// when the project closes.
    var quitAppsOnClose: [String] = []
    /// A claude.ai chat or project link, opened in the Claude desktop app.
    var claudeLink: String = ""
    /// What happens to the Claude app when the project closes: "quit", "hide" or "leave".
    var claudeOnClose: String = "minimise"
    /// Optional due date, shown as a countdown in the menu.
    var deadline: Date? = nil
    /// Saved window positions, one layout per screen setup (see ScreenSetup).
    var layouts: [String: [SavedFrame]] = [:]
    /// Finished work sessions.
    var timeLog: [WorkSession] = []
    /// Set while the project is open.
    var activeSession: ActiveSession? = nil
    /// Finished with: hidden from the menu and Raycast, but its time still counts.
    var archived: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, groupID, files, urls, braveWindowNames, icon, color, hideAppsOnClose, minimiseAppsOnClose, quitAppsOnClose, claudeLink, claudeOnClose
        case deadline, layouts, timeLog, activeSession, archived
        case legacyParentID = "parentID"
    }
}

extension Project {
    private enum LegacyKeys: String, CodingKey { case braveWindowName }

    /// Tolerant decoding, so projects saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Project"
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        legacyParentID = try c.decodeIfPresent(UUID.self, forKey: .legacyParentID)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        braveWindowNames = try c.decodeIfPresent([String].self, forKey: .braveWindowNames) ?? []
        // Up to 1.11 a project had one Brave window.
        if braveWindowNames.isEmpty,
           let old = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .braveWindowName),
           !old.isEmpty {
            braveWindowNames = [old]
        }
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "doc.text"
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        hideAppsOnClose = try c.decodeIfPresent([String].self, forKey: .hideAppsOnClose) ?? []
        minimiseAppsOnClose = try c.decodeIfPresent([String].self, forKey: .minimiseAppsOnClose) ?? []
        quitAppsOnClose = try c.decodeIfPresent([String].self, forKey: .quitAppsOnClose) ?? []
        claudeLink = try c.decodeIfPresent(String.self, forKey: .claudeLink) ?? ""
        claudeOnClose = try c.decodeIfPresent(String.self, forKey: .claudeOnClose) ?? "minimise"
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        layouts = try c.decodeIfPresent([String: [SavedFrame]].self, forKey: .layouts) ?? [:]
        timeLog = try c.decodeIfPresent([WorkSession].self, forKey: .timeLog) ?? []
        activeSession = try c.decodeIfPresent(ActiveSession.self, forKey: .activeSession)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    /// Whether the project has anything to open.
    var hasContent: Bool {
        !files.isEmpty || !urls.isEmpty || !braveWindowNames.isEmpty || !claudeLink.isEmpty
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
    /// Named groups of projects (e.g. "Radiation"), shown as submenus.
    @Published var groups: [ProjectGroup] = [] {
        didSet { save() }
    }
    /// Which projects are currently "open" (ticked).
    @Published private(set) var openIDs: Set<UUID> = []
    /// Which project the editor window shows.
    @Published var editorSelection: UUID?
    /// What the check a few seconds after opening or closing found wrong, by project.
    @Published private(set) var problems: [UUID: Problem] = [:]
    /// Set when GitHub has a newer version than this build.
    @Published private(set) var updateAvailable = false

    private let fileURL: URL
    private var timer: Timer?
    private var updateTimer: Timer?

    /// ~/Library/Application Support/ProjectLauncher
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectLauncher", isDirectory: true)
    }

    init() {
        let support = Self.dataFolder
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("projects.json")
        load()
        finishStaleSessions()
        Backups.makeIfDue()
        RaycastScripts.sync(projects: projects, groups: groups)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        URLEvents.shared.handler = { [weak self] url in self?.handle(url) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        // Look for updates shortly after launch, then every 4 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            MainActor.assumeIsolated { self?.checkForUpdates() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    func checkForUpdates() {
        Updater.checkForUpdates { [weak self] available in self?.updateAvailable = available }
    }

    // MARK: Open / close

    func isOpen(_ p: Project) -> Bool { openIDs.contains(p.id) }

    func toggle(_ p: Project) {
        // Use the latest saved version, not the copy the menu was drawn with.
        guard let current = projects.first(where: { $0.id == p.id }) else { return }
        if isOpen(current) { close(current) } else { open(current) }
    }

    /// Settings key: opening a project closes the others first (hold Option to keep them).
    static let closeOthersKey = "closeOthersOnOpen"

    func open(_ p: Project, keepOthers: Bool = NSEvent.modifierFlags.contains(.option)) {
        pausedIDs.remove(p.id)
        let closeOthers = UserDefaults.standard.object(forKey: Self.closeOthersKey) as? Bool ?? true
        if closeOthers && !keepOthers {
            for other in projects where other.id != p.id && isOpen(other) {
                close(other, keepingFor: p)
            }
        }
        problems[p.id] = nil
        openIDs.insert(p.id)
        Launcher.open(p, stillOpen: { [weak self] in self?.openIDs.contains(p.id) ?? false })
        let now = Date()
        update(p.id) { $0.activeSession = ActiveSession(start: now, lastBeat: now) }
        scheduleCheck(p.id, opened: true)
    }

    /// `next`: the project about to open instead, whose apps, files and windows are left alone.
    func close(_ p: Project, keepingFor next: Project? = nil) {
        problems[p.id] = nil
        pausedIDs.remove(p.id)
        var keep = appsInUse(except: p.id)
        if let next { keep.formUnion(apps(of: next)) }
        Launcher.close(p, keepRunning: keep, keeping: next)
        openIDs.remove(p.id)
        endSession(p.id)
        scheduleCheck(p.id, opened: false)
    }

    /// Apps another open project still uses (its files' apps, and Claude if it has a chat),
    /// which closing shouldn't quit or hide.
    private func appsInUse(except id: UUID) -> Set<String> {
        Set(projects.filter { $0.id != id && isOpen($0) }.flatMap(apps(of:)))
    }

    /// The apps a project uses: its files' apps, and Claude if it has a chat.
    private func apps(of p: Project) -> Set<String> {
        var apps = Set(p.files.compactMap(appBundleID))
        if let claude = ClaudeApp.bundleID(), !p.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty {
            apps.insert(claude)
        }
        return apps
    }

    // MARK: Archive

    /// Archiving closes the project if it's open.
    func setArchived(_ id: UUID, _ archived: Bool) {
        if archived, let p = projects.first(where: { $0.id == id }), isOpen(p) { close(p) }
        update(id) { $0.archived = archived }
    }

    // MARK: Links (projectlauncher://toggle?id=..., also open, close, closeall; or ?name=...)

    func handle(_ url: URL) {
        guard url.scheme == "projectlauncher" else { return }
        let action = url.host ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = items.first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
        let name = items.first { $0.name == "name" }?.value?.lowercased()
        Log.write("LINK \(url.absoluteString)")
        if action == "closeall" { closeAll(); return }
        let target = projects.first { $0.id == id }
            ?? projects.first { !$0.archived && $0.name.lowercased() == name }
            ?? name.flatMap { n in projects.first { !$0.archived && $0.name.lowercased().contains(n) } }
        guard let p = target else { return }
        switch action {
        case "open": if !isOpen(p) { open(p, keepOthers: false) }
        case "close": if isOpen(p) { close(p) }
        default: if isOpen(p) { close(p) } else { open(p, keepOthers: false) }
        }
    }

    // MARK: Checking it worked

    /// 5 seconds after opening or closing, checks everything opened or closed.
    /// Apps like Word (closing OneDrive files) and MATLAB (quitting) can take a few seconds.
    private func scheduleCheck(_ id: UUID, opened: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.projects.first(where: { $0.id == id }),
                      self.isOpen(p) == opened else { return } // toggled again since
                Verify.snapshot(for: p) { [weak self] snap in
                    guard let self, let p = self.projects.first(where: { $0.id == id }),
                          self.isOpen(p) == opened else { return }
                    let issues = opened ? Verify.afterOpen(p, snap)
                        : Verify.afterClose(p, keepRunning: self.appsInUse(except: id), snap)
                    Log.write("CHECK \(opened ? "open" : "close") \(p.name): " + (issues.isEmpty ? "all OK" : issues.map(\.text).joined(separator: "; ")))
                    self.problems[id] = issues.isEmpty ? nil : Problem(opened: opened, issues: issues)
                }
            }
        }
    }

    /// Runs the open or close again, then checks again.
    func tryAgain(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }), let problem = problems[id] else { return }
        problems[id] = nil
        Log.write("TRY AGAIN \(problem.opened ? "open" : "close") \(p.name)")
        if problem.opened {
            Launcher.open(p, stillOpen: { [weak self] in self?.openIDs.contains(id) ?? false })
        } else { Launcher.close(p, keepRunning: appsInUse(except: id)) }
        scheduleCheck(id, opened: problem.opened)
    }

    /// Quits an app (e.g. Word) still holding documents that didn't close, then checks again.
    func quitStuckApp(_ appID: String, for id: UUID) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: appID) {
            Log.write("QUIT \(app.localizedName ?? appID) (documents didn't close)")
            app.terminate()
        }
        problems[id] = nil
        scheduleCheck(id, opened: false)
    }

    func dismissProblem(_ id: UUID) {
        problems[id] = nil
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

    // MARK: Pausing while away

    /// Settings key: minutes without keyboard or mouse before time stops counting (0 = never).
    static let idleMinutesKey = "idlePauseMinutes"

    /// Open projects whose time is paused because you're away.
    @Published private(set) var pausedIDs: Set<UUID> = []
    private var resumeTimer: Timer?

    func isPaused(_ p: Project) -> Bool { pausedIDs.contains(p.id) }

    /// Called every minute: if there's been no input for the set time, stop counting,
    /// back-dated to the last input, and watch for your return.
    private func pauseIfAway() {
        let minutes = UserDefaults.standard.object(forKey: Self.idleMinutesKey) as? Int ?? 10
        guard minutes > 0 else { return }
        let idle = Idle.seconds()
        guard idle >= Double(minutes * 60) else { return }
        let lastInput = Date().addingTimeInterval(-idle)
        for p in projects where isOpen(p) && p.activeSession != nil {
            endSession(p.id, at: lastInput)
            pausedIDs.insert(p.id)
            Log.write("PAUSE \(p.name): no keyboard or mouse for \(Int(idle / 60)) min")
        }
        guard !pausedIDs.isEmpty, resumeTimer == nil else { return }
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resumeIfBack() }
        }
    }

    private func resumeIfBack() {
        let idle = Idle.seconds()
        guard idle < 10 else { return }
        let back = Date().addingTimeInterval(-idle)
        for id in pausedIDs {
            guard let p = projects.first(where: { $0.id == id }), isOpen(p) else { continue }
            update(id) { $0.activeSession = ActiveSession(start: back, lastBeat: Date()) }
            Log.write("RESUME \(p.name)")
        }
        pausedIDs = []
        resumeTimer?.invalidate()
        resumeTimer = nil
    }

    /// Runs every minute. A gap of more than 3 minutes means the Mac was asleep:
    /// log up to the last beat and start a fresh session from now.
    func heartbeat() {
        pauseIfAway()
        flushSave()
        Backups.makeIfDue()
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
        ScreenSetup.nameCurrentIfNeeded()
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
        Alerts.show("Saved for \(ScreenSetup.label(key))",
                    lines.joined(separator: "\n")
                    + "\n\nNext time you open these projects with the same screens, the windows go back to these positions.")
    }

    func captureNewProject() {
        var p = Capture.currentProject()
        let apps = Capture.openApps(besides: p.files)
        if p.files.isEmpty && p.braveWindowNames.isEmpty && p.claudeLink.isEmpty && apps.isEmpty {
            Alerts.show("Nothing to capture",
                        "Open the files, apps, Brave window and Claude chat you want first, then try again. Project Launcher also needs Accessibility permission (System Settings > Privacy & Security > Accessibility) to see your open windows.")
            return
        }
        if !apps.isEmpty {
            guard let chosen = Alerts.confirm(
                "Which apps are part of this project?",
                "Ticked apps open with the project, and their window minimises when it closes. Your documents, Brave window and Claude chat are added too.",
                ok: "Create Project", apps: apps) else { return }
            p.files.append(contentsOf: chosen)
            p.minimiseAppsOnClose.append(contentsOf: chosen)
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

    /// Adds what's open now to an existing project: new documents (not ones another open
    /// project has), the front Brave window if it isn't in the project, and the Claude chat
    /// if it has none yet. Asks first,
    /// then saves the window layout for this screen setup too.
    func updateFromOpenWindows(_ id: UUID) {
        guard let p = projects.first(where: { $0.id == id }) else { return }
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: expandPath(path)).resolvingSymlinksInPath().path
        }
        let taken = Set((projects.filter { $0.id == id || isOpen($0) }).flatMap { $0.files.map(resolved) })
        let newFiles = Capture.openFiles().filter { !taken.contains(resolved($0)) }
        let brave = Brave.captureFrontWindow().flatMap { p.braveWindowNames.contains($0) ? nil : $0 }
        let claude = p.claudeLink.isEmpty ? ClaudeApp.currentLink() : nil
        // Apps not already in this or another open project.
        let newApps = Capture.openApps(besides: p.files + newFiles)
            .filter { !taken.contains(resolved($0)) }

        var lines = newFiles.map { "• " + ($0 as NSString).lastPathComponent }
        if let brave { lines.append("• Brave window: \(brave)") }
        if claude != nil { lines.append("• The Claude chat that's open now") }
        var message = lines.isEmpty && newApps.isEmpty
            ? "Nothing new is open. Save the current window positions for \(p.name)?"
            : "Add to \(p.name):\n\n" + lines.joined(separator: "\n")
              + "\n\nThe current window positions are saved too. You can remove anything later in Edit Projects."
        if lines.isEmpty && !newApps.isEmpty { message = "Add the ticked apps to \(p.name)? The current window positions are saved too." }
        let ok = lines.isEmpty && newApps.isEmpty ? "Save Layout" : "Add"
        var chosenApps: [String] = []
        if newApps.isEmpty {
            guard Alerts.confirm("Update \(p.name)?", message, ok: ok) else { return }
        } else {
            guard let chosen = Alerts.confirm("Update \(p.name)?", message, ok: ok, apps: newApps) else { return }
            chosenApps = chosen
        }

        Log.write("UPDATE \(p.name): added \(newFiles) apps=\(chosenApps) brave=\(brave ?? "-") claude=\(claude ?? "-")")
        update(id) { q in
            q.files.append(contentsOf: newFiles + chosenApps)
            q.minimiseAppsOnClose.append(contentsOf: chosenApps)
            if let brave { q.braveWindowNames.append(brave) }
            if let claude { q.claudeLink = claude }
        }
        if let updated = projects.first(where: { $0.id == id }) {
            let frames = Layouts.capture(updated)
            if !frames.isEmpty { update(id) { $0.layouts[ScreenSetup.currentKey()] = frames } }
        }
    }

    // MARK: Backups

    /// Replaces every project and group with a backup's. Asks first, and backs up
    /// the current list so the restore can be undone.
    func restoreBackup(from folder: URL) {
        guard openIDs.isEmpty else {
            Alerts.show("Close your projects first", "Restoring replaces every project, so close the open ones (Close All Projects) and try again.")
            return
        }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("projects.json")),
              let restored = try? JSONDecoder().decode([Project].self, from: data) else {
            Alerts.show("That isn't a backup", "Choose a backup folder (named like \"2026-11-21 09.30\") with projects.json inside.")
            return
        }
        let restoredGroups = (try? Data(contentsOf: folder.appendingPathComponent("groups.json")))
            .flatMap { try? JSONDecoder().decode([ProjectGroup].self, from: $0) } ?? []
        guard Alerts.confirm("Restore \(restored.count) projects from \(folder.lastPathComponent)?",
                             "This replaces your \(projects.count) current projects and their time logs. They're backed up first, so you can restore them again if needed.",
                             ok: "Restore") else { return }
        flushSave()
        Backups.make(note: " (before restore)")
        Log.write("RESTORE from \(folder.path)")
        editorSelection = nil
        groups = restoredGroups
        projects = restored
        migrateSubProjects()
        finishStaleSessions()
    }

    // MARK: Groups

    /// Projects in a group (or ungrouped) that aren't archived, for the menu and sidebar.
    func activeProjects(in groupID: UUID?) -> [Project] {
        projects(in: groupID).filter { !$0.archived }
    }

    var archivedProjects: [Project] { projects.filter(\.archived) }

    /// All projects in a group (or ungrouped), archived ones included.
    func projects(in groupID: UUID?) -> [Project] {
        let ids = Set(groups.map(\.id))
        return projects.filter { p in
            guard let g = groupID else { return p.groupID == nil || !ids.contains(p.groupID!) }
            return p.groupID == g
        }
    }

    func group(of p: Project) -> ProjectGroup? {
        groups.first { $0.id == p.groupID }
    }

    /// e.g. "Radiation › Assignment 1", or just the name if it isn't in a group.
    func displayName(_ p: Project) -> String {
        group(of: p).map { "\($0.name) › \(p.name)" } ?? p.name
    }

    /// Time spent across every project in a group.
    func groupTime(_ groupID: UUID, since: Date? = nil) -> TimeInterval {
        projects(in: groupID).reduce(0) { $0 + $1.timeSpent(since: since) }
    }

    // MARK: Editing

    func addProject(group: UUID? = nil) -> UUID {
        var p = Project(name: "New Project")
        p.groupID = group
        projects.append(p)
        return p.id
    }

    /// A copy set up the same way (files, links, windows, layouts), with no time logged,
    /// placed just after the original.
    func duplicate(_ id: UUID) -> UUID? {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = projects[i]
        copy.id = UUID()
        copy.name += " copy"
        copy.timeLog = []
        copy.activeSession = nil
        copy.archived = false
        projects.insert(copy, at: i + 1)
        return copy.id
    }

    func addGroup() -> UUID {
        let g = ProjectGroup()
        groups.append(g)
        return g.id
    }

    /// Deletes a project, or a group (its projects stay, just ungrouped).
    func delete(id: UUID) {
        if groups.contains(where: { $0.id == id }) {
            groups.removeAll { $0.id == id }
            var copy = projects
            for i in copy.indices where copy[i].groupID == id { copy[i].groupID = nil }
            projects = copy
            return
        }
        projects.removeAll { $0.id == id }
        openIDs.remove(id)
    }

    private func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[i])
    }

    // MARK: Persistence (~/Library/Application Support/ProjectLauncher/projects.json and groups.json)

    private var groupsURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("groups.json") }

    private func load() {
        if let data = try? Data(contentsOf: groupsURL),
           let decoded = try? JSONDecoder().decode([ProjectGroup].self, from: data) {
            groups = decoded
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Project].self, from: data) else { return }
        projects = decoded
        migrateSubProjects()
        migrateHideToMinimise()
    }

    /// Before 1.19, closing hid apps and Claude (all their windows). Minimising only the
    /// project's window is the default now, so switch them over once.
    private func migrateHideToMinimise() {
        let key = "migratedHideToMinimise"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        var copy = projects
        for i in copy.indices {
            copy[i].minimiseAppsOnClose += copy[i].hideAppsOnClose.filter { !copy[i].minimiseAppsOnClose.contains($0) }
            copy[i].hideAppsOnClose = []
            if copy[i].claudeOnClose == "hide" { copy[i].claudeOnClose = "minimise" }
        }
        if copy != projects { projects = copy }
    }

    /// Version 1.2 to 1.12 nested projects under other projects. Each top-level parent becomes
    /// a group holding everything below it. A parent that was only a container (no files,
    /// links or time) is removed; one with its own content stays as a project in the group.
    private func migrateSubProjects() {
        guard projects.contains(where: { $0.legacyParentID != nil }) else { return }
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func root(_ p: Project) -> Project {
            var current = p
            var seen: Set<UUID> = [p.id]
            while let parent = current.legacyParentID.flatMap({ byID[$0] }), seen.insert(parent.id).inserted {
                current = parent
            }
            return current
        }
        var newGroups: [UUID: ProjectGroup] = [:]
        var copy = projects
        for i in copy.indices where copy[i].legacyParentID != nil {
            let top = root(copy[i])
            guard top.id != copy[i].id else { continue }
            if newGroups[top.id] == nil { newGroups[top.id] = ProjectGroup(name: top.name) }
            copy[i].groupID = newGroups[top.id]!.id
        }
        var remove: Set<UUID> = []
        for (topID, g) in newGroups {
            guard let i = copy.firstIndex(where: { $0.id == topID }) else { continue }
            if copy[i].hasContent || !copy[i].timeLog.isEmpty {
                copy[i].groupID = g.id
            } else {
                remove.insert(topID)
            }
        }
        copy.removeAll { remove.contains($0.id) }
        for i in copy.indices { copy[i].legacyParentID = nil }
        groups.append(contentsOf: newGroups.values.sorted { $0.name < $1.name })
        projects = copy
    }

    /// Saving waits until changes stop for a moment (e.g. while typing a name), then writes once.
    private var pendingSave: DispatchWorkItem?

    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes any change still waiting (before quitting or backing up).
    func flushSave() {
        guard let work = pendingSave, !work.isCancelled else { return }
        work.cancel()
        saveNow()
    }

    private func saveNow() {
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) {
            try? data.write(to: fileURL, options: .atomic)
        }
        if let data = try? encoder.encode(groups) {
            try? data.write(to: groupsURL, options: .atomic)
        }
        RaycastScripts.sync(projects: projects, groups: groups)
    }
}

// MARK: - Problems found by the check after opening or closing

struct Issue: Hashable {
    var text: String
    /// The app holding a document that didn't close, so it can be quit instead.
    var stuckApp: String? = nil
}

struct Problem: Hashable {
    var opened: Bool
    var issues: [Issue]
    var stuckApps: Set<String> { Set(issues.compactMap(\.stuckApp)) }
    /// e.g. "1 window still open" or "2 things didn't open".
    var summary: String {
        let n = issues.count
        return opened ? "\(n) thing\(n == 1 ? "" : "s") didn't open" : "\(n) thing\(n == 1 ? "" : "s") still open"
    }
}

// MARK: - Helpers

enum Idle {
    /// Seconds since the last keyboard, mouse or trackpad input.
    static func seconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

func expandPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// The app that opens a file or link by default. Asking macOS is slow-ish and the menu and
/// editor ask often, so answers are remembered for a few minutes.
func defaultApp(for url: URL) -> URL? {
    let key = url.absoluteString as NSString
    if let hit = AppLookupCache.shared.object(forKey: key), hit.time.timeIntervalSinceNow > -300 { return hit.app }
    let app = NSWorkspace.shared.urlForApplication(toOpen: url)
    AppLookupCache.shared.setObject(AppLookup(app: app), forKey: key)
    return app
}

final class AppLookup {
    let app: URL?
    let time = Date()
    init(app: URL?) { self.app = app }
}

enum AppLookupCache {
    static let shared = NSCache<NSString, AppLookup>()
}

func isApp(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "app"
}

/// Apps whose documents can't be closed one at a time from outside (MATLAB's files are tabs
/// in one window, invisible to Accessibility and scripting). Their files close the whole app.
private let wholeAppDocumentApps: Set<String> = ["com.mathworks.matlab"]

/// The app that closing this entry quits or hides: the app itself for a .app,
/// or e.g. MATLAB for a .m file. nil for ordinary documents.
func wholeAppBundleID(_ path: String) -> String? {
    let url = URL(fileURLWithPath: expandPath(path))
    if isApp(path) { return Bundle(url: url)?.bundleIdentifier }
    guard let appURL = defaultApp(for: url),
          let id = Bundle(url: appURL)?.bundleIdentifier, wholeAppDocumentApps.contains(id) else { return nil }
    return id
}

/// The app that opens this entry: the app itself for a .app, otherwise the file's default app.
func appBundleID(_ path: String) -> String? {
    let url = URL(fileURLWithPath: expandPath(path))
    if isApp(path) { return Bundle(url: url)?.bundleIdentifier }
    return defaultApp(for: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
}

let officeAppIDs: Set<String> = ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint"]

/// A Word, Excel or PowerPoint document.
func isOfficeDocument(_ path: String) -> Bool {
    !isApp(path) && appBundleID(path).map(officeAppIDs.contains) == true
}

/// A document (not a .app) that can only be closed by closing its whole app.
func closesWholeApp(_ path: String) -> Bool {
    !isApp(path) && wholeAppBundleID(path) != nil
}

func formatDuration(_ t: TimeInterval) -> String {
    let mins = Int(t / 60)
    if mins < 60 { return "\(mins)m" }
    return "\(mins / 60)h \(mins % 60)m"
}

/// "due in 3 days", "due tomorrow", "due today", "2 days overdue".
func deadlineText(_ deadline: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: deadline)).day ?? 0
    if days < -1 { return "\(-days) days overdue" }
    if days == -1 { return "1 day overdue" }
    if days == 0 { return "due today" }
    if days == 1 { return "due tomorrow" }
    return "due in \(days) days"
}
