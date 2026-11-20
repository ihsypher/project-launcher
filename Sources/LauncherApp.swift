import SwiftUI
import AppKit

@main
struct LauncherApp: App {
    @StateObject private var store = ProjectStore()

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
        ForEach(store.projects) { project in
            Toggle(isOn: Binding(
                get: { store.isOpen(project) },
                set: { _ in store.toggle(project) }
            )) {
                Text(label(for: project))
            }
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

    /// e.g. "ANIHC  (3 days left, 1h 20m today)"
    private func label(for p: Project) -> String {
        var extras: [String] = []
        if let d = p.deadline { extras.append(deadlineText(d)) }
        if store.isOpen(p) {
            let today = p.timeSpent(since: Calendar.current.startOfDay(for: Date()))
            extras.append("\(formatDuration(today)) today")
        }
        return extras.isEmpty ? p.name : "\(p.name)  (\(extras.joined(separator: ", ")))"
    }
}

/// Hosts the SwiftUI editor in a normal AppKit window, so it reliably comes
/// to the front even though this is a menu-bar-only app.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    static let shared = EditorWindow()
    private var window: NSWindow?

    func show(store: ProjectStore) {
        if window == nil {
            let root = EditorView()
                .environmentObject(store)
                .frame(minWidth: 680, minHeight: 440)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Project Launcher"
            w.setContentSize(NSSize(width: 780, height: 520))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        // While editing, behave like a normal app (Dock icon, Cmd-Tab, menu bar)
        // so Cmd-C / Cmd-V / Cmd-A work in the text fields.
        NSApp.setActivationPolicy(.regular)
        installEditMenu()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to being menu-bar only.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Menu-bar-only apps have no Edit menu, and without one the standard
    /// copy/paste shortcuts do nothing. Build a minimal menu bar.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Project Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
