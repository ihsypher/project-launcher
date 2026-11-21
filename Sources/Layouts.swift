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

        // Apps added to the project: the window saved before if it's still there, else the front one.
        let before = p.layouts[ScreenSetup.currentKey()] ?? []
        for path in p.files where isApp(path) {
            guard let id = Bundle(url: URL(fileURLWithPath: expandPath(path)))?.bundleIdentifier else { continue }
            let saved = before.first { $0.kind == "app" && $0.key == path }
            let found = saved.flatMap { AppWindows.find(id, $0, fallback: false) }
            guard let w = found ?? AppWindows.front(id), let r = AX.frame(of: w) else { continue }
            var f = SavedFrame(kind: "app", key: path, rect: r)
            f.title = AX.string(w, kAXTitleAttribute)
            if id == Terminal.bundleID, let t = f.title { f.tty = Terminal.tty(windowNamed: t) }
            frames.append(f)
        }

        // Brave windows
        for name in p.braveWindowNames.map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if let r = Brave.bounds(windowName: name) {
                frames.append(SavedFrame(kind: "brave", key: name, rect: r))
            }
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
                    Log.write("  [layout] move \(AX.describe(item.window))")
                    AX.setFrame(item.window, f.rect)
                }
            }
        }

        for f in frames {
            switch f.kind {
            case "app":
                if let id = Bundle(url: URL(fileURLWithPath: expandPath(f.key)))?.bundleIdentifier,
                   let w = AppWindows.find(id, f, fallback: true) {
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

    /// Windows take a moment to appear after opening, so apply a few times as they do
    /// (at 0.3s, 0.6s, 1s, 1.5s, 2.5s and 4s), unless the project has been closed again
    /// in the meantime. Windows already in place don't move.
    static func applySoon(_ frames: [SavedFrame], while stillOpen: @escaping @MainActor () -> Bool) {
        Task { @MainActor in
            for delay in [0.3, 0.3, 0.4, 0.5, 1.0, 1.5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard stillOpen() else { return }
                apply(frames)
            }
        }
    }
}

// MARK: - Telling an app's windows apart

/// Finds the window a saved app frame belongs to (e.g. one of several Terminal windows),
/// minimised ones included.
@MainActor
enum AppWindows {
    static func all(_ bundleID: String) -> [AXUIElement] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .flatMap { AX.windows(pid: $0.processIdentifier) }
            // Minimised windows report themselves as dialogs (Terminal does), so keep those too.
            .filter { AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole || AX.isMinimized($0) }
    }

    /// The front visible window.
    static func front(_ bundleID: String) -> AXUIElement? {
        all(bundleID).first { !AX.isMinimized($0) }
    }

    /// Matches by Terminal tty, then exact title, then the title's first part
    /// (Terminal starts it with the folder, e.g. "ProjectLauncher — -zsh — 80×24").
    /// Frames saved before windows were told apart (no title) use the front window,
    /// and with `fallback` so does an app with only one window.
    static func find(_ bundleID: String, _ f: SavedFrame, fallback: Bool) -> AXUIElement? {
        let windows = all(bundleID)
        guard let title = f.title else { return fallback ? front(bundleID) : nil }
        func titled(_ t: String) -> AXUIElement? { windows.first { AX.string($0, kAXTitleAttribute) == t } }

        if bundleID == Terminal.bundleID, let tty = f.tty,
           let now = Terminal.windowName(tty: tty), let w = titled(now) { return w }
        if let w = titled(title) { return w }
        let head = firstPart(title)
        if !head.isEmpty, let w = windows.first(where: { firstPart(AX.string($0, kAXTitleAttribute) ?? "") == head }) {
            return w
        }
        return fallback && windows.count == 1 ? windows[0] : nil
    }

    /// The windows a project uses: the one it saved a position for, or else every window
    /// (it can't tell which one is the project's).
    static func projectWindows(_ bundleID: String, path: String, in p: Project) -> [AXUIElement] {
        let saved = p.layouts[ScreenSetup.currentKey()]?.first { $0.kind == "app" && $0.key == path }
        if let saved, saved.title != nil { return find(bundleID, saved, fallback: false).map { [$0] } ?? [] }
        return all(bundleID)
    }

    private static func firstPart(_ title: String) -> String {
        title.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// Terminal windows have no document, but each tab has a tty that stays the same while
/// Terminal is running.
@MainActor
enum Terminal {
    static let bundleID = "com.apple.Terminal"

    static func tty(windowNamed name: String) -> String? {
        ask("""
        tell application "Terminal"
            repeat with w in windows
                if name of w is "\(Brave.escape(name))" then return tty of selected tab of w
            end repeat
        end tell
        return ""
        """)
    }

    static func windowName(tty: String) -> String? {
        ask("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(Brave.escape(tty))" then return name of w
                end repeat
            end repeat
        end tell
        return ""
        """)
    }

    private static func ask(_ source: String) -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error { Log.write("  [terminal] \(error[NSAppleScript.errorMessage] ?? error)") }
        return (result?.isEmpty ?? true) ? nil : result
    }
}

// MARK: - "New Project from What's Open"

@MainActor
enum Capture {
    static func currentProject() -> Project {
        var p = Project()
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        p.name = "Captured \(formatter.string(from: Date()))"
        p.files = openFiles()
        if let name = Brave.captureFrontWindow() { p.braveWindowNames = [name] }
        if let link = ClaudeApp.currentLink() { p.claudeLink = link }
        return p
    }

    /// Documents open right now, as ~-abbreviated paths.
    static func openFiles() -> [String] {
        var paths: [String] = []
        func add(_ path: String) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder) else { return }
            // Folders aren't documents (Terminal reports its current folder as one), but
            // document packages like .pages or .key are.
            if isFolder.boolValue && !NSWorkspace.shared.isFilePackage(atPath: resolved) { return }
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
        // Preview, asked directly so documents in background tabs are included too.
        for path in Scripting.previewDocumentPaths() { add(path) }

        return paths
    }

    /// Apps showing a window that aren't covered by the documents, Brave or Claude
    /// (e.g. Terminal or MATLAB), as ~-abbreviated .app paths.
    static func openApps(besides files: [String]) -> [String] {
        guard AX.ensureTrusted(prompt: false) else { return [] }
        var skip: Set<String> = [
            Bundle.main.bundleIdentifier ?? "",
            "com.apple.finder",
            Brave.bundleID,
            ClaudeApp.bundleID() ?? "",
        ]
        // Apps whose documents were captured (Word, Preview...) or that are already in the project.
        for f in files { if let id = appBundleID(f) { skip.insert(id) } }

        var paths: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden {
            guard let id = app.bundleIdentifier, !skip.contains(id), let url = app.bundleURL else { continue }
            let hasWindow = AX.windows(pid: app.processIdentifier).contains {
                !AX.isMinimized($0) && AX.string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole
            }
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            if hasWindow && !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// Apps that are usually open for everything, so they start unticked when capturing.
    static let everydayApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.mail", "com.apple.Music", "com.spotify.client",
        "com.apple.systempreferences", "com.apple.iCal", "com.apple.ActivityMonitor",
        "com.apple.AppStore", "com.apple.FaceTime", "net.whatsapp.WhatsApp", "com.hnc.Discord",
        "com.tinyspeck.slackmacgap", "com.apple.Photos", "com.apple.reminders", "com.apple.Notes",
        "com.microsoft.teams2", "us.zoom.xos", "com.apple.Safari", "com.google.Chrome",
    ]
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
    /// Whether GitHub has commits this build doesn't. Runs git in the background
    /// (fetch only, so nothing local changes) and calls back on the main thread.
    static func checkForUpdates(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let dir = Bundle.main.object(forInfoDictionaryKey: "PLSourceDir") as? String else { return }
        DispatchQueue.global(qos: .utility).async {
            let available = git(dir, ["fetch", "--quiet"]) != nil
                && (Int(git(dir, ["rev-list", "--count", "HEAD..@{u}"]) ?? "") ?? 0) > 0
            DispatchQueue.main.async { MainActor.assumeIsolated { done(available) } }
        }
    }

    /// Runs git in `dir`; returns its trimmed output, or nil if it failed.
    nonisolated private static func git(_ dir: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        // Never stop to ask for a GitHub login.
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
