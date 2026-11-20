import SwiftUI
import AppKit
import ServiceManagement

// MARK: - projectlauncher:// links (used by the Raycast commands)

/// Receives projectlauncher:// links. Installed once the app has finished launching,
/// so it takes over from SwiftUI's own handler.
@MainActor
final class URLEvents: NSObject {
    static let shared = URLEvents()
    var handler: ((URL) -> Void)?

    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        handler?(url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { URLEvents.shared.install() }
    }
}

// MARK: - Raycast script commands

/// Keeps one Raycast script command per project in a folder you add to Raycast
/// (Settings > Extensions > Script Commands > Add Directories). Searching a project's
/// name in Raycast then opens or closes it.
@MainActor
enum RaycastScripts {
    static let enabledKey = "raycastScripts"
    private static let prefix = "pl-"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProjectLauncher/Raycast", isDirectory: true)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func sync(projects: [Project], groups: [ProjectGroup]) {
        let fm = FileManager.default
        guard isEnabled else {
            try? fm.removeItem(at: folder)
            return
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var wanted: [String: String] = [:]
        for p in projects where !p.archived {
            let group = groups.first { $0.id == p.groupID }?.name
            let title = group.map { "\($0) › \(p.name)" } ?? p.name
            let file = prefix + safeName(p.name) + "-" + p.id.uuidString.prefix(8) + ".sh"
            wanted[file] = script(title: title, description: "Open or close this project",
                                  icon: iconFile(p.icon, p.color), url: "projectlauncher://toggle?id=\(p.id.uuidString)")
        }
        wanted[prefix + "close-all.sh"] = script(title: "Close All Projects", description: "Close every open project",
                                                 icon: iconFile("xmark", "gray"), url: "projectlauncher://closeall")

        let existing = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in existing where name.hasPrefix(prefix) && wanted[name] == nil {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        for (name, text) in wanted {
            let url = folder.appendingPathComponent(name)
            guard (try? String(contentsOf: url, encoding: .utf8)) != text else { continue }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private static func script(title: String, description: String, icon: String, url: String) -> String {
        """
        #!/bin/bash
        # Made by Project Launcher. Changes here are overwritten.
        # @raycast.schemaVersion 1
        # @raycast.title \(title)
        # @raycast.mode silent
        # @raycast.packageName Project Launcher
        # @raycast.icon \(icon)
        # @raycast.description \(description)
        open -g "\(url)"

        """
    }

    /// The project's icon tile as a PNG (made once per icon and colour), for Raycast to show.
    private static func iconFile(_ icon: String, _ color: String) -> String {
        let name = "icon-\(icon)-\(color).png"
        let url = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            let renderer = ImageRenderer(content: ProjectIcon(icon: icon, color: color, size: 64).padding(4))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
        return name
    }

    private static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(String(cleaned).split(separator: "-").joined(separator: "-").prefix(40))
    }
}

// MARK: - Open at login

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Alerts.show("Couldn't change Open at Login", error.localizedDescription)
        }
    }
}
