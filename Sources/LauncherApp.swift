import SwiftUI
import AppKit

@main
struct LauncherApp: App {
    @StateObject private var store = ProjectStore()

    init() {
        MainActor.assumeIsolated { ClaudeApp.prepareAccessibility() }
    }

    var body: some Scene {
        // The icon turns into a warning while something didn't open or close properly.
        MenuBarExtra("Project Launcher",
                     systemImage: store.problems.isEmpty ? "square.stack.3d.up" : "exclamationmark.triangle") {
            MenuContent()
                .environmentObject(store)
        }
    }
}

/// The drop-down menu shown when you click the menu-bar icon.
struct MenuContent: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        if store.projects.isEmpty {
            Text("No projects yet")
        }

        // Anything the check after opening/closing found wrong.
        ForEach(store.projects.filter { store.problems[$0.id] != nil }) { p in
            if let problem = store.problems[p.id] {
                Menu("⚠︎ \(p.name): \(problem.summary)") {
                    ForEach(problem.issues, id: \.self) { Text($0.text) }
                    Divider()
                    Button("Try Again") { store.tryAgain(p.id) }
                    if !problem.opened {
                        ForEach(Array(problem.stuckApps).sorted(), id: \.self) { appID in
                            Button("Quit \(appDisplayName(appID))") { store.quitStuckApp(appID, for: p.id) }
                        }
                    }
                    Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                    Button("Dismiss") { store.dismissProblem(p.id) }
                }
            }
        }
        if !store.problems.isEmpty { Divider() }

        // Each project is a toggle: a tick means it's open. Click to open/close.
        // Groups are submenus of their projects.
        ForEach(store.projects(in: nil)) { project in
            ProjectToggle(project: project)
        }
        ForEach(store.groups) { group in
            GroupMenu(group: group)
        }

        Divider()

        Button("Save Window Layout of Open Projects") { store.saveLayoutsForOpenProjects() }
            .disabled(store.openIDs.isEmpty)
        Button("New Project from Open Windows") { store.captureNewProject() }
        updateMenu
        Button("Close All Open Projects") { store.closeAll() }
            .disabled(store.openIDs.isEmpty)

        Divider()

        Button("Edit Projects...") { EditorWindow.shared.show(store: store) }
            .keyboardShortcut(",")
        Button(store.updateAvailable ? "Update Available: Install Now..." : "Update Project Launcher...") {
            Updater.run()
        }

        Divider()

        Button("Quit Project Launcher") {
            store.prepareToQuit()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Adds newly opened documents to an open project. Picks the project directly
    /// if only one is open, otherwise offers a submenu.
    @ViewBuilder private var updateMenu: some View {
        let open = store.projects.filter { store.isOpen($0) }
        if open.count == 1, let p = open.first {
            Button("Update \(p.name) from Open Windows") { store.updateFromOpenWindows(p.id) }
        } else {
            Menu("Update Project from Open Windows") {
                ForEach(open) { p in
                    Button(store.displayName(p)) { store.updateFromOpenWindows(p.id) }
                }
            }
            .disabled(open.isEmpty)
        }
    }

}

/// e.g. "Word" for com.microsoft.Word.
@MainActor
func appDisplayName(_ appID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else { return appID }
    let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    return name.replacingOccurrences(of: "Microsoft ", with: "")
}

/// One project in the menu: a tick means it's open. Click to open/close.
struct ProjectToggle: View {
    @EnvironmentObject var store: ProjectStore
    let project: Project

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.isOpen(project) },
            set: { _ in store.toggle(project) }
        )) {
            Label(label, systemImage: project.icon)
        }
    }

    /// e.g. "ANIHC  (due in 3 days, 1h 20m today)"
    private var label: String {
        var extras: [String] = []
        if let d = project.deadline { extras.append(deadlineText(d)) }
        if store.isOpen(project) {
            let today = project.timeSpent(since: Calendar.current.startOfDay(for: Date()))
            extras.append("\(formatDuration(today)) today")
        }
        return extras.isEmpty ? project.name : "\(project.name)  (\(extras.joined(separator: ", ")))"
    }
}

/// A group in the menu: a submenu of its projects.
struct GroupMenu: View {
    @EnvironmentObject var store: ProjectStore
    let group: ProjectGroup

    var body: some View {
        let members = store.projects(in: group.id)
        Menu {
            if members.isEmpty { Text("No projects in this group") }
            ForEach(members) { ProjectToggle(project: $0) }
        } label: {
            Label(label(members), systemImage: "folder")
        }
    }

    /// e.g. "Radiation  (1 open, 2h 10m today, next due in 3 days)"
    private func label(_ members: [Project]) -> String {
        var extras: [String] = []
        let open = members.filter { store.isOpen($0) }.count
        if open > 0 { extras.append("\(open) open") }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let today = store.groupTime(group.id, since: startOfDay)
        if today >= 60 { extras.append("\(formatDuration(today)) today") }
        if let next = members.compactMap(\.deadline).filter({ $0 >= startOfDay }).min() {
            extras.append("next \(deadlineText(next))")
        }
        return extras.isEmpty ? group.name : "\(group.name)  (\(extras.joined(separator: ", ")))"
    }
}

/// Hosts the SwiftUI editor in a normal AppKit window, so it reliably comes
/// to the front even though this is a menu-bar-only app.
@MainActor
final class EditorWindow: NSObject {
    static let shared = EditorWindow()
    private var window: NSWindow?

    func show(store: ProjectStore) {
        if window == nil {
            let root = EditorView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 480)
            let w = ShortcutWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Project Launcher"
            w.setContentSize(NSSize(width: 860, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Stays menu-bar only (no Dock icon) while editing.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Menu-bar-only apps have no Edit menu, and without one the standard
/// copy/paste shortcuts do nothing. This window handles them itself.
final class ShortcutWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = mods.contains(.shift)
        let action: Selector?
        switch (key, shift) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        case ("w", false): performClose(nil); return true
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
