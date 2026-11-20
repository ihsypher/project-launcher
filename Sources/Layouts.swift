import AppKit

// MARK: - Screen setups

/// Identifies which screens are connected, e.g. "Built-in Retina Display 1512x982"
/// or "Built-in Retina Display 1512x982 + DELL U2720Q 2560x1440".
/// Each project keeps one window layout per screen setup.
@MainActor
enum ScreenSetup {
    static func currentKey() -> String {
        NSScreen.screens
            .map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            .sorted()
            .joined(separator: " + ")
    }
}

// MARK: - Saving and restoring window positions

@MainActor
enum Layouts {
    /// Records where this project's windows are right now.
    static func capture(_ p: Project) -> [SavedFrame] {
        guard AX.ensureTrusted() else { return [] }
        var frames: [SavedFrame] = []

        // Documents (Preview, Word, Excel...)
        var seen = Set<String>()
        let docs = p.files.filter { !isApp($0) }
        for item in AX.documentWindows(files: docs)
        where !AX.isMinimized(item.window) && !seen.contains(item.path) {
            if let r = AX.frame(of: item.window) {
                frames.append(SavedFrame(kind: "file", key: item.path, rect: r))
                seen.insert(item.path)
            }
        }

        // Apps added to the project
        for path in p.files where isApp(path) {
            if let id = Bundle(url: URL(fileURLWithPath: expandPath(path)))?.bundleIdentifier,
               let w = AX.firstWindow(bundleID: id), let r = AX.frame(of: w) {
                frames.append(SavedFrame(kind: "app", key: path, rect: r))
            }
        }

        // Brave window
        let name = p.braveWindowName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let r = Brave.bounds(windowName: name) {
            frames.append(SavedFrame(kind: "brave", key: name, rect: r))
        }

        // Claude
        if !p.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty,
           let w = ClaudeApp.mainWindow(), let r = AX.frame(of: w) {
            frames.append(SavedFrame(kind: "claude", key: "claude", rect: r))
        }
        return frames
    }

    /// Moves windows back to their saved positions.
    static func apply(_ frames: [SavedFrame]) {
        guard AX.ensureTrusted(prompt: false) else { return }

        let fileFrames = frames.filter { $0.kind == "file" }
        if !fileFrames.isEmpty {
            for item in AX.documentWindows(files: fileFrames.map { $0.key }) {
                if let f = fileFrames.first(where: { $0.key == item.path }) {
                    AX.setFrame(item.window, f.rect)
                }
            }
        }

        for f in frames {
            switch f.kind {
            case "app":
                if let id = Bundle(url: URL(fileURLWithPath: expandPath(f.key)))?.bundleIdentifier,
                   let w = AX.firstWindow(bundleID: id) {
                    AX.setFrame(w, f.rect)
                }
            case "brave":
                Brave.setBounds(windowName: f.key, f.rect)
            case "claude":
                if let w = ClaudeApp.mainWindow() { AX.setFrame(w, f.rect) }
            default:
                break
            }
        }
    }

    /// Windows take a moment to appear after opening, so apply twice.
    static func applySoon(_ frames: [SavedFrame]) {
        Task { @MainActor in
            for delay in [1.5, 3.5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                apply(frames)
            }
        }
    }
}

// MARK: - "New Project from Open Windows"

@MainActor
enum Capture {
    static func currentProject() -> Project {
        var p = Project()
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        p.name = "Captured \(formatter.string(from: Date()))"

        var paths: [String] = []
        func add(_ path: String) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard FileManager.default.fileExists(atPath: resolved) else { return }
            let short = (resolved as NSString).abbreviatingWithTildeInPath
            if !paths.contains(short) { paths.append(short) }
        }

        // Documents in any app that reports them (Preview, TextEdit, Pages, often Office too).
        let skip: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.finder",
            Brave.bundleID,
            ClaudeApp.bundleID() ?? "",
        ]
        if AX.ensureTrusted() {
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && !app.isHidden {
                guard let id = app.bundleIdentifier, !skip.contains(id) else { continue }
                for w in AX.windows(pid: app.processIdentifier) where !AX.isMinimized(w) {
                    if let doc = AX.string(w, kAXDocumentAttribute) {
                        if let url = URL(string: doc), url.isFileURL {
                            add(url.path)
                        } else if let local = OneDrive.localPath(for: doc) {
                            add(local)
                        }
                    }
                }
            }
        }

        // Word, Excel and PowerPoint, asked directly in case they don't report documents above.
        for path in Office.openDocumentPaths() { add(path) }

        p.files = paths
        if let name = Brave.captureFrontWindow() { p.braveWindowName = name }
        if let link = ClaudeApp.currentLink() { p.claudeLink = link }
        return p
    }
}

/// Word, Excel and PowerPoint report OneDrive and SharePoint files as web addresses
/// ("https://...sharepoint.com/personal/.../Documents/Folder/File.docx").
/// This finds the synced copy under ~/Library/CloudStorage/OneDrive-....
enum OneDrive {
    static func localPath(for address: String) -> String? {
        let decoded = address.removingPercentEncoding ?? address
        let lower = decoded.lowercased()
        guard lower.hasPrefix("https://"),
              lower.contains("sharepoint.com") || lower.contains("onedrive"),
              let range = decoded.range(of: "Documents/") else { return nil }
        let relative = String(decoded[range.upperBound...])
        guard !relative.isEmpty else { return nil }

        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let fm = FileManager.default
        // Current folders before dated leftovers like "OneDrive-School (15-09-2026 11:29 am)".
        let roots = ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? [])
            .filter { $0.hasPrefix("OneDrive") }
            .sorted { a, b in
                let aDated = a.contains(" ("), bDated = b.contains(" (")
                return aDated == bDated ? a < b : !aDated
            }
        for root in roots {
            let base = storage.appendingPathComponent(root, isDirectory: true)
            var candidates = [base.appendingPathComponent(relative)]
            // Shared libraries sit one folder deeper (one per site).
            for library in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                candidates.append(base.appendingPathComponent(library).appendingPathComponent(relative))
            }
            if let hit = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return hit.path }
        }
        return nil
    }
}

@MainActor
enum Office {
    struct OpenDocument {
        var appID: String
        var collection: String
        var path: String
        var name: String
    }

    private static let apps: [(id: String, collection: String, element: String)] = [
        ("com.microsoft.Word", "documents", "document"),
        ("com.microsoft.Excel", "workbooks", "workbook"),
        ("com.microsoft.Powerpoint", "presentations", "presentation"),
    ]

    static func openDocumentPaths() -> [String] {
        openDocuments().map(\.path)
    }

    /// Documents open in Word, Excel and PowerPoint, asked over AppleScript.
    /// Finds them even when Accessibility can't see the window (e.g. full screen in another Space).
    static func openDocuments() -> [OpenDocument] {
        var out: [OpenDocument] = []
        for app in apps where !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty {
            // Office returns old-style "Macintosh HD:Users:..." paths; convert outside the tell block.
            let script = """
            set theFull to {}
            set theNames to {}
            tell application id "\(app.id)"
                try
                    set theFull to full name of \(app.collection)
                    set theNames to name of \(app.collection)
                end try
            end tell
            set out to {}
            repeat with i from 1 to (count of theFull)
                set t to (item i of theFull) as text
                set p to ""
                if t starts with "/" or t contains "://" then
                    set p to t
                else if t contains ":" then
                    try
                        set p to POSIX path of t
                    end try
                end if
                if p is not "" and i ≤ (count of theNames) then
                    set end of out to {p, (item i of theNames) as text}
                end if
            end repeat
            return out
            """
            guard let r = AppleScriptRunner.result(script), r.numberOfItems > 0 else { continue }
            for i in 1...r.numberOfItems {
                guard let pair = r.atIndex(i), pair.numberOfItems == 2,
                      var path = pair.atIndex(1)?.stringValue,
                      let name = pair.atIndex(2)?.stringValue else { continue }
                if path.contains("://") {
                    guard let local = OneDrive.localPath(for: path) else { continue }
                    path = local
                }
                out.append(OpenDocument(appID: app.id, collection: app.collection, path: path, name: name))
            }
        }
        return out
    }

    /// Asks Office to close these documents ("saving ask", so unsaved work still prompts).
    /// Doesn't wait for a reply, so a save prompt can't freeze Project Launcher.
    static func close(_ docs: [OpenDocument]) {
        for doc in docs {
            guard let element = apps.first(where: { $0.id == doc.appID })?.element else { continue }
            let name = doc.name.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
            AppleScriptRunner.result("""
            ignoring application responses
                tell application id "\(doc.appID)"
                    try
                        close \(element) "\(name)" saving ask
                    end try
                end tell
            end ignoring
            """)
        }
    }
}

// MARK: - Updating from GitHub

@MainActor
enum Updater {
    /// Opens update.command (in the folder the app was built from) in Terminal.
    /// It pulls the latest code, rebuilds, and reinstalls.
    static func run() {
        guard let dir = Bundle.main.object(forInfoDictionaryKey: "PLSourceDir") as? String else {
            Alerts.show("Can't find the source folder",
                        "Run ./update.command once from the ProjectLauncher folder in Terminal. After that, this menu item will work.")
            return
        }
        let script = URL(fileURLWithPath: dir).appendingPathComponent("update.command")
        guard FileManager.default.fileExists(atPath: script.path) else {
            Alerts.show("Can't find update.command",
                        "It should be in \(dir). If you moved the folder, run ./update.command from its new location once.")
            return
        }
        NSWorkspace.shared.open(script)
    }
}
