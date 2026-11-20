import AppKit
import ApplicationServices

// MARK: - Top-level open / close

@MainActor
enum Launcher {
    static func open(_ p: Project) {
        var missing: [String] = []
        for path in p.files {
            let full = expandPath(path)
            if FileManager.default.fileExists(atPath: full) {
                NSWorkspace.shared.open(URL(fileURLWithPath: full))
            } else {
                missing.append(path)
            }
        }
        if !missing.isEmpty {
            Alerts.show("Some files couldn't be found",
                        "These may have been moved or renamed:\n\n" + missing.joined(separator: "\n"))
        }
        Brave.show(windowName: p.braveWindowName, urls: p.urls)
        // Claude last, so the chat ends up in front.
        ClaudeApp.open(link: p.claudeLink)
        // Put windows back where they were saved for this screen setup.
        if let frames = p.layouts[ScreenSetup.currentKey()], !frames.isEmpty {
            Layouts.applySoon(frames)
        }
    }

    static func close(_ p: Project) {
        // Close ONLY this project's document windows. Apps stay running,
        // so other modules' files in Word/Excel/Preview are untouched.
        let docs = p.files.filter { !isApp($0) }
        if !docs.isEmpty {
            WindowCloser.close(files: docs)
        }
        // Apps added to the project (e.g. Claude.app): quit them, or hide if chosen.
        for path in p.files where isApp(path) {
            guard let bundleID = Bundle(url: URL(fileURLWithPath: expandPath(path)))?.bundleIdentifier else { continue }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                if p.hideAppsOnClose.contains(path) {
                    app.hide()
                } else {
                    app.terminate()
                }
            }
        }
        if !p.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty {
            ClaudeApp.close(mode: p.claudeOnClose)
        }
        // Minimise (not close) the named Brave window.
        let name = p.braveWindowName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            Brave.minimise(windowName: name)
        }
    }
}

// MARK: - Claude desktop app (via claude:// links)

@MainActor
enum ClaudeApp {
    /// Turns "https://claude.ai/chat/<id>" (or "claude.ai/project/<id>") into
    /// "claude://claude.ai/chat/<id>", which the Claude desktop app opens directly.
    static func deepLink(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.lowercased().hasPrefix("claude://") { return URL(string: s) }
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        guard s.lowercased().hasPrefix("claude.ai/") else { return nil }
        return URL(string: "claude://" + s)
    }

    static func open(link: String) {
        guard !link.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let url = deepLink(from: link) else {
            Alerts.show("That Claude link doesn't look right",
                        "Paste a link like https://claude.ai/chat/... or https://claude.ai/project/...\n\n\(link)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Bundle ID of whichever app handles claude:// links (the Claude desktop app).
    static func bundleID() -> String? {
        guard let probe = URL(string: "claude://claude.ai/new"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func mainWindow() -> AXUIElement? {
        guard let id = bundleID() else { return nil }
        return AX.firstWindow(bundleID: id)
    }

    static func close(mode: String) {
        guard mode != "leave", let bundleID = bundleID() else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            if mode == "quit" { app.terminate() } else { app.hide() }
        }
    }
}

// MARK: - Brave (via AppleScript)

@MainActor
enum Brave {
    static let appName = "Brave Browser"

    /// If a window with this name exists: un-minimise it and bring it to the front.
    /// Otherwise: open the URLs in a new window and try to give it the name.
    static func show(windowName: String, urls: [String]) {
        let name = windowName.trimmingCharacters(in: .whitespaces)
        let cleanURLs = urls
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if name.isEmpty && cleanURLs.isEmpty { return }

        let urlList = "{" + cleanURLs.map { "\"\(escape($0))\"" }.joined(separator: ", ") + "}"

        let script = """
        set wantedName to "\(escape(name))"
        set theURLs to \(urlList)
        if application "\(appName)" is not running then
            tell application "\(appName)" to launch
            -- give Brave time to restore its windows (named windows come back with the session)
            repeat 20 times
                delay 0.25
                try
                    if (count of windows of application "\(appName)") > 0 then exit repeat
                end try
            end repeat
            delay 0.5
        end if
        tell application "\(appName)"
            set found to missing value
            if wantedName is not "" then
                repeat with w in windows
                    try
                        if (given name of w) is wantedName then
                            set found to contents of w
                            exit repeat
                        end if
                    end try
                end repeat
            end if
            if found is not missing value then
                set minimized of found to false
                set index of found to 1
            else if (count of theURLs) > 0 then
                set newWin to make new window
                set URL of active tab of newWin to item 1 of theURLs
                repeat with i from 2 to (count of theURLs)
                    make new tab at end of tabs of newWin with properties {URL:(item i of theURLs)}
                end repeat
                if wantedName is not "" then
                    try
                        set given name of newWin to wantedName
                    end try
                end if
            end if
            activate
        end tell
        """
        AppleScriptRunner.run(script)
    }

    static let bundleID = "com.brave.Browser"

    /// The names you've given Brave windows (Window > Name Window...), for the editor's dropdown.
    /// Doesn't launch Brave if it's closed.
    static func windowNames() -> (names: [String], error: String?) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return ([], "Brave isn't open. Open it, then press refresh.")
        }
        let script = """
        tell application "\(appName)"
            set out to {}
            repeat with w in windows
                try
                    set n to given name of w
                    if n is not missing value and n is not "" then set end of out to n
                end try
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            let msg = err[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            return ([], "Couldn't read Brave's windows: \(msg)\nIf this mentions permission, allow Project Launcher in System Settings > Privacy & Security > Automation.")
        }
        var names: [String] = []
        if let result = result, result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let s = result.atIndex(i)?.stringValue, !s.isEmpty, !names.contains(s) {
                    names.append(s)
                }
            }
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        if names.isEmpty {
            return ([], "No named Brave windows found. In Brave, use Window > Name Window..., then press refresh.")
        }
        return (names, nil)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Position of the named window, in screen points (top-left origin, same as Accessibility).
    static func bounds(windowName: String) -> CGRect? {
        guard isRunning, !windowName.isEmpty else { return nil }
        let script = """
        tell application "\(appName)"
            repeat with w in windows
                try
                    if (given name of w) is "\(escape(windowName))" then return bounds of w
                end try
            end repeat
        end tell
        return {}
        """
        guard let r = AppleScriptRunner.result(script), r.numberOfItems == 4 else { return nil }
        let v = (1...4).map { Double(r.atIndex($0)?.int32Value ?? 0) }
        return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
    }

    static func setBounds(windowName: String, _ r: CGRect) {
        guard isRunning, !windowName.isEmpty else { return }
        let l = Int(r.minX.rounded()), t = Int(r.minY.rounded())
        let rt = Int(r.maxX.rounded()), b = Int(r.maxY.rounded())
        let script = """
        tell application "\(appName)"
            repeat with w in windows
                try
                    if (given name of w) is "\(escape(windowName))" then
                        set minimized of w to false
                        set bounds of w to {\(l), \(t), \(rt), \(b)}
                    end if
                end try
            end repeat
        end tell
        """
        AppleScriptRunner.result(script)
    }

    /// The Brave window you're in (front-most, not minimised), for "New Project from Open Windows".
    /// If it has no name yet, asks for one (suggesting the current tab's title) and names it in Brave.
    static func captureFrontWindow() -> String? {
        guard isRunning else { return nil }
        let script = """
        tell application "\(appName)"
            repeat with w in windows
                try
                    if (minimized of w) is false then
                        set n to given name of w
                        if n is missing value then set n to ""
                        set t to ""
                        try
                            set t to title of active tab of w
                        end try
                        return {(id of w) as text, n, t}
                    end if
                end try
            end repeat
        end tell
        return {}
        """
        guard let r = AppleScriptRunner.result(script), r.numberOfItems == 3,
              let windowID = r.atIndex(1)?.stringValue else { return nil }
        let given = r.atIndex(2)?.stringValue ?? ""
        if !given.isEmpty { return given }

        let tabTitle = r.atIndex(3)?.stringValue ?? ""
        guard let name = Alerts.askText(
            "Name this Brave window?",
            "Your front Brave window has no name. Project Launcher finds the window by its name, so give it one to include it in the project.",
            suggestion: tabTitle, okTitle: "Name Window", cancelTitle: "Skip Brave"
        ) else { return nil }

        let set = """
        tell application "\(appName)"
            set given name of (first window whose id is \(windowID)) to "\(escape(name))"
        end tell
        """
        return AppleScriptRunner.run(set) ? name : nil
    }

    static func minimise(windowName: String) {
        let script = """
        if application "\(appName)" is running then
            tell application "\(appName)"
                repeat with w in windows
                    try
                        if (given name of w) is "\(escape(windowName))" then
                            set minimized of w to true
                        end if
                    end try
                end repeat
            end tell
        end if
        """
        AppleScriptRunner.run(script)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

@MainActor
enum AppleScriptRunner {
    /// Runs a script and returns its result, without showing an alert on failure.
    @discardableResult
    static func result(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            NSLog("ProjectLauncher AppleScript error: \(error)")
            return nil
        }
        return r
    }

    @discardableResult
    static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            NSLog("ProjectLauncher AppleScript error: \(error)")
            Alerts.show("Couldn't control Brave",
                        message + "\n\nIf this mentions permission, allow Project Launcher in System Settings > Privacy & Security > Automation.")
            return false
        }
        return true
    }
}

// MARK: - Accessibility helpers (finding, moving and closing windows)

@MainActor
enum AX {
    /// Prompts for Accessibility permission the first time (if `prompt`).
    static func ensureTrusted(prompt: Bool = true) -> Bool {
        // Same key as kAXTrustedCheckOptionPrompt, written out to avoid a Swift 6 concurrency warning.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func string(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef = posRef, let sizeRef = sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        var pos = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Size, move, then size again: some apps clamp the size until the window is on the right screen.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    /// First visible window of an app.
    static func firstWindow(bundleID: String) -> AXUIElement? {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            if let w = windows(pid: app.processIdentifier).first(where: { !isMinimized($0) }) {
                return w
            }
        }
        return nil
    }

    /// Windows showing any of the given files, each paired with the path as stored in the project.
    /// Looks in every running app, since a file may be open in something other than its default app.
    static func documentWindows(files: [String]) -> [(path: String, window: AXUIElement)] {
        let targets = files.map { ($0, URL(fileURLWithPath: expandPath($0)).resolvingSymlinksInPath()) }
        var result: [(path: String, window: AXUIElement)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            for w in windows(pid: app.processIdentifier) {
                if let path = matchingPath(w, targets) {
                    result.append((path: path, window: w))
                }
            }
        }
        return result
    }

    /// True while a window shows a sheet, e.g. "Do you want to save changes?".
    static func hasSheet(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return false }
        return children.contains { string($0, kAXRoleAttribute) == "AXSheet" }
    }

    /// Match by the window's document path (Preview, most Cocoa apps),
    /// falling back to the window title (Word, Excel).
    private static func matchingPath(_ window: AXUIElement, _ targets: [(String, URL)]) -> String? {
        if let doc = string(window, kAXDocumentAttribute), let docURL = URL(string: doc) {
            let docPath = docURL.resolvingSymlinksInPath().path
            if let t = targets.first(where: { $0.1.path == docPath }) { return t.0 }
        }
        if let title = string(window, kAXTitleAttribute) {
            // Word/Excel add suffixes like "Lab3_report - Compatibility Mode" or "Lab3_data [Read-Only]".
            // Only accept those, so a file called "Lab3" doesn't match "Lab3 notes".
            let separators = [" - ", " \u{2013} ", " \u{2014} ", " [", " ("]
            for (path, url) in targets {
                let name = url.lastPathComponent
                let stem = url.deletingPathExtension().lastPathComponent
                if title == name || title == stem { return path }
                for base in [name, stem] where separators.contains(where: { title.hasPrefix(base + $0) }) {
                    return path
                }
            }
        }
        return nil
    }

    /// Presses the red close button, so apps ask to save unsaved work as usual.
    static func pressClose(_ window: AXUIElement) {
        // A minimised window's close button may not respond, so restore it first.
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button = button {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }
}

@MainActor
enum WindowCloser {
    /// Seconds after the first try to look again. Apps can ignore a press while busy,
    /// and closing one Preview tab brings the next one forward as a new window.
    private static let retryDelays: [Double] = [0.7, 1.5, 3]

    static func close(files: [String]) {
        guard AX.ensureTrusted() else {
            Alerts.show("Accessibility permission needed",
                        "To close only this project's windows, allow Project Launcher in System Settings > Privacy & Security > Accessibility, then try again.")
            return
        }
        pressAll(files)
        for (i, delay) in retryDelays.enumerated() {
            let last = i == retryDelays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    let seen = pressAll(files)
                    if last { closeOfficeLeftovers(files, skipping: seen) }
                }
            }
        }
    }

    /// Presses close on each matching window, leaving alone any that are asking to save.
    /// Returns the paths that still have a window.
    @discardableResult
    private static func pressAll(_ files: [String]) -> Set<String> {
        var seen: Set<String> = []
        for item in AX.documentWindows(files: files) {
            seen.insert(item.path)
            if !AX.hasSheet(item.window) { AX.pressClose(item.window) }
        }
        return seen
    }

    /// Word/Excel/PowerPoint documents still open that Accessibility couldn't see at all.
    private static func closeOfficeLeftovers(_ files: [String], skipping seen: Set<String>) {
        let wanted = Set(files.filter { !seen.contains($0) }.map {
            URL(fileURLWithPath: expandPath($0)).resolvingSymlinksInPath().path
        })
        let leftovers = Office.openDocuments().filter {
            wanted.contains(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path)
        }
        if !leftovers.isEmpty { Office.close(leftovers) }
    }
}

// MARK: - Alerts

@MainActor
enum Alerts {
    static func show(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Asks for a line of text. Returns nil if cancelled or left empty.
    static func askText(_ title: String, _ message: String, suggestion: String,
                        okTitle: String, cancelTitle: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: cancelTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = suggestion
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
