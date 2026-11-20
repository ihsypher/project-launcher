import SwiftUI
import AppKit

@main
struct LauncherApp: App {
    @StateObject private var store = ProjectStore()

    init() {
        MainActor.assumeIsolated { ClaudeApp.prepareAccessibility() }
    }

    var body: some Scene {
        MenuBarExtra("Project Launcher", systemImage: "square.stack.3d.up") {
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

        // Each project is a toggle: a tick means it's open. Click to open/close.
        // Projects with sub-projects become submenus.
        ForEach(store.children(of: nil)) { project in
            ProjectMenuItem(project: project)
        }

        Divider()

        Button("Save Window Layout of Open Projects") { store.saveLayoutsForOpenProjects() }
            .disabled(store.openIDs.isEmpty)
        Button("New Project from Open Windows") { store.captureNewProject() }
        Button("Close All Open Projects") { store.closeAll() }
            .disabled(store.openIDs.isEmpty)

        Divider()

        Button("Edit Projects...") { EditorWindow.shared.show(store: store) }
            .keyboardShortcut(",")
        Button("Update Project Launcher...") { Updater.run() }

        Divider()

        Button("Quit Project Launcher") {
            store.prepareToQuit()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

}

/// One project in the menu: a toggle, or a submenu if it has sub-projects.
struct ProjectMenuItem: View {
    @EnvironmentObject var store: ProjectStore
    let project: Project

    var body: some View {
        let kids = store.children(of: project.id)
        if kids.isEmpty {
            toggle
        } else {
            Menu(groupLabel) {
                // A parent with its own files etc. can be opened too (e.g. shared course notes).
                if project.hasContent {
                    toggle
                    Divider()
                }
                ForEach(kids) { child in
                    ProjectMenuItem(project: child)
                }
            }
        }
    }

    private var toggle: some View {
        Toggle(isOn: Binding(
            get: { store.isOpen(project) },
            set: { _ in store.toggle(project) }
        )) {
            Text(label)
        }
    }

    /// e.g. "ANIHC  (3 days left, 1h 20m today)"
    private var label: String {
        var extras: [String] = []
        if let d = project.deadline { extras.append(deadlineText(d)) }
        if store.isOpen(project) {
            let today = project.timeSpent(since: Calendar.current.startOfDay(for: Date()))
            extras.append("\(formatDuration(today)) today")
        }
        return extras.isEmpty ? project.name : "\(project.name)  (\(extras.joined(separator: ", ")))"
    }

    /// e.g. "Radiation  (1 open, next: 3 days left)"
    private var groupLabel: String {
        let all = [project] + store.descendants(of: project.id)
        var extras: [String] = []
        let open = all.filter { store.isOpen($0) }.count
        if open > 0 { extras.append("\(open) open") }
        let today = Calendar.current.startOfDay(for: Date())
        if let next = all.compactMap(\.deadline).filter({ $0 >= today }).min() {
            extras.append("next: \(deadlineText(next))")
        }
        return extras.isEmpty ? project.name : "\(project.name)  (\(extras.joined(separator: ", ")))"
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
                .frame(minWidth: 680, minHeight: 440)
            let w = ShortcutWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Project Launcher"
            w.setContentSize(NSSize(width: 780, height: 520))
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
