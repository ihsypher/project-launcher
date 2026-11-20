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
                    if let doc = AX.string(w, kAXDocumentAttribute),
                       let url = URL(string: doc), url.isFileURL {
                        add(url.path)
                    }
                }
            }
        }

        // Word, Excel and PowerPoint, asked directly in case they don't report documents above.
        for path in Office.openDocumentPaths() { add(path) }

        p.files = paths
        if let name = Brave.frontNamedWindow() { p.braveWindowName = name }
        return p
    }
}

@MainActor
enum Office {
    static func openDocumentPaths() -> [String] {
        let apps: [(id: String, collection: String)] = [
            ("com.microsoft.Word", "documents"),
            ("com.microsoft.Excel", "workbooks"),
            ("com.microsoft.Powerpoint", "presentations"),
        ]
        var out: [String] = []
        for app in apps where !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty {
            // Office returns old-style "Macintosh HD:Users:..." paths; convert outside the tell block.
            let script = """
            set theNames to {}
            tell application id "\(app.id)"
                try
                    set theNames to full name of \(app.collection)
                end try
            end tell
            set out to {}
            repeat with n in theNames
                set t to n as text
                if t starts with "/" then
                    set end of out to t
                else if t contains ":" and t does not contain "://" then
                    try
                        set end of out to POSIX path of t
                    end try
                end if
            end repeat
            return out
            """
            guard let r = AppleScriptRunner.result(script), r.numberOfItems > 0 else { continue }
            for i in 1...r.numberOfItems {
                if let s = r.atIndex(i)?.stringValue { out.append(s) }
            }
        }
        return out
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
