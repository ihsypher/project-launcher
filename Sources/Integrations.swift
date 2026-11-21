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

// MARK: - Backups

/// Copies of projects.json and groups.json, one folder per backup ("2026-11-21 09.30").
/// Made once a day automatically, kept in iCloud Drive when it's on so they survive a new Mac.
@MainActor
enum Backups {
    static let keep = 30

    static var folder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) {
            return iCloud.appendingPathComponent("Project Launcher Backups", isDirectory: true)
        }
        return ProjectStore.dataFolder.appendingPathComponent("Backups", isDirectory: true)
    }

    static var isInICloud: Bool { folder.path.contains("Mobile Documents") }

    /// Backups, newest first.
    static func all() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// A backup if there isn't one from today yet.
    static func makeIfDue() {
        let today = stamp(Date()).prefix(10)
        if !all().contains(where: { $0.lastPathComponent.hasPrefix(today) }) { make() }
    }

    @discardableResult
    static func make(note: String = "") -> URL? {
        let fm = FileManager.default
        let source = ProjectStore.dataFolder
        guard fm.fileExists(atPath: source.appendingPathComponent("projects.json").path) else { return nil }
        let target = folder.appendingPathComponent(stamp(Date()) + note, isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["projects.json", "groups.json"] {
                let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.removeItem(at: to)
                try fm.copyItem(at: from, to: to)
            }
        } catch {
            Log.write("BACKUP failed: \(error.localizedDescription)")
            return nil
        }
        Log.write("BACKUP \(target.path)")
        for old in all().dropFirst(keep) { try? fm.removeItem(at: old) }
        return target
    }

    static func lastBackupText() -> String {
        guard let latest = all().first,
              let date = (try? latest.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return "No backups yet" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last backup " + f.localizedString(for: date, relativeTo: Date())
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: date)
    }
}
