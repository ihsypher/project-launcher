import AppKit
import ApplicationServices

// MARK: - Top-level open / close

@MainActor
enum Launcher {
    /// `stillOpen` stops the layout being re-applied once the project has been closed again.
    static func open(_ p: Project, stillOpen: @escaping @MainActor () -> Bool = { true }) {
        Log.write("OPEN \(p.name): files=\(p.files) brave=\(p.braveWindowNames) claude=\(p.claudeLink)")
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
        // Backup pages go with the first window, if it isn't open.
        let windows = p.braveWindowNames.isEmpty ? [""] : p.braveWindowNames
        for (i, name) in windows.enumerated() {
            Brave.show(windowName: name, urls: i == 0 ? p.urls : [])
        }
        // Minimised app windows without a saved position (those are restored with the layout).
        let placed = Set((p.layouts[ScreenSetup.currentKey()] ?? []).filter { $0.kind == "app" }.map(\.key))
        for path in p.files where p.minimiseAppsOnClose.contains(path) && !placed.contains(path) {
            if let id = wholeAppBundleID(path) {
                AppWindows.projectWindows(id, path: path, in: p).forEach { AX.setMinimized($0, false) }
            }
        }
        // Claude last, so the chat ends up in front.
        ClaudeApp.open(link: p.claudeLink)
        // Put windows back where they were saved for this screen setup.
        // (Only for files still in the project: a removed file's saved position is ignored.)
        if let frames = p.layouts[ScreenSetup.currentKey()]?.filter({ $0.kind != "file" || p.files.contains($0.key) }),
           !frames.isEmpty {
            Layouts.applySoon(frames, while: stillOpen)
        }
    }

    /// `keepRunning`: bundle IDs of apps another open project still uses.
    /// `next`: a project opening straight after, whose files and Brave windows stay open.
    static func close(_ p: Project, keepRunning: Set<String> = [], keeping next: Project? = nil) {
        Log.write("CLOSE \(p.name): files=\(p.files)" + (next.map { " (switching to \($0.name))" } ?? ""))
        // Close ONLY this project's document windows. Apps stay running,
        // so other modules' files in Word/Excel/Preview are untouched.
        let shared = Set((next?.files ?? []).map(expandPath))
        let docs = p.files.filter { wholeAppBundleID($0) == nil && !shared.contains(expandPath($0)) }
        if !docs.isEmpty {
            WindowCloser.close(files: docs)
        }
        // Apps added to the project (e.g. Claude.app), and apps like MATLAB whose files
        // can't be closed one by one: quit them, or hide if chosen.
        var handled: Set<String> = []
        for path in p.files {
            guard let bundleID = wholeAppBundleID(path), handled.insert(bundleID).inserted else { continue }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard let name = apps.first?.localizedName else { continue }
            if keepRunning.contains(bundleID) {
                Log.write("  leave \(name) running: another open project uses it")
            } else if p.minimiseAppsOnClose.contains(path) {
                let windows = AppWindows.projectWindows(bundleID, path: path, in: p)
                Log.write("  minimise \(windows.count) \(name) window(s)")
                windows.forEach { AX.setMinimized($0, true) }
            } else if p.hideAppsOnClose.contains(path) {
                Log.write("  hide app \(name)")
                apps.forEach { $0.hide() }
            } else {
                Log.write("  quit app \(name)")
                apps.forEach { $0.terminate() }
                // Some apps (MATLAB) take a while, or stop to ask about unsaved work.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if apps.contains(where: { !$0.isTerminated }) {
                        Log.write("  \(name) still running 10s after quitting (slow, or asking to save?)")
                    }
                }
            }
        }
        // Word/Excel/PowerPoint set to quit with the project, after their files have been closed.
        let officeToQuit = Set(p.quitAppsOnClose.filter { p.files.contains($0) }.compactMap(appBundleID))
        for appID in officeToQuit {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            guard let name = apps.first?.localizedName else { continue }
            if keepRunning.contains(appID) {
                Log.write("  leave \(name) running: another open project uses it")
                continue
            }
            Log.write("  quit app \(name) (set to quit with this project)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { apps.forEach { $0.terminate() } }
        }
        if !p.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty {
            if let id = ClaudeApp.bundleID(), keepRunning.contains(id) {
                Log.write("  leave Claude: another open project uses it")
            } else {
                ClaudeApp.close(mode: p.claudeOnClose)
            }
        }
        // Minimise (not close) the named Brave windows.
        for name in p.braveWindowNames.map({ $0.trimmingCharacters(in: .whitespaces) })
        where !name.isEmpty && next?.braveWindowNames.contains(name) != true {
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
        restoreMinimised()
    }

    /// Bundle ID of whichever app handles claude:// links (the Claude desktop app).
    static func bundleID() -> String? {
        guard let probe = URL(string: "claude://claude.ai/new"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// The chat or project open in the Claude app, e.g. "https://claude.ai/chat/<id>",
    /// read from its window through Accessibility. nil if Claude isn't open or is on another page.
    static func currentLink() -> String? {
        guard let id = bundleID(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
              AX.ensureTrusted(prompt: false) else { return nil }
        prepareAccessibility()
        // The first time, Claude can take a couple of seconds to build its tree.
        for attempt in 0..<12 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.25) }
            for window in AX.windows(pid: app.processIdentifier) where !AX.isMinimized(window) {
                for url in AX.webAreaURLs(in: window) {
                    if let link = chatLink(from: url) { return link }
                }
            }
        }
        return nil
    }

    /// Claude is an Electron app: it only exposes its pages to Accessibility once asked to.
    /// Called at launch too, so capture is quick later.
    static func prepareAccessibility() {
        guard let id = bundleID(), AX.ensureTrusted(prompt: false) else { return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// Keeps only claude.ai chat and project pages, without any "?..." or "#..." on the end.
    private static func chatLink(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "claude.ai" || host.hasSuffix(".claude.ai") else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, ["chat", "project"].contains(parts[0].lowercased()) else { return nil }
        return "https://claude.ai/\(parts[0])/\(parts[1])"
    }

    static func mainWindow() -> AXUIElement? {
        guard let id = bundleID() else { return nil }
        return AX.firstWindow(bundleID: id)
    }

    static let freshOnCloseKey = "claudeFreshOnClose"

    /// With the setting on (default), Claude is first switched to a new chat and made to fill
    /// the screen, so opening it by itself later starts fresh rather than on the project's chat.
    static func close(mode: String) {
        guard mode != "leave", bundleID() != nil else { return }
        let fresh = UserDefaults.standard.object(forKey: freshOnCloseKey) as? Bool ?? true
        guard fresh, mode != "quit", let home = URL(string: "claude://claude.ai/new") else {
            putAway(mode: mode)
            return
        }
        Log.write("  Claude: new chat, fill screen")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(home, configuration: config)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                fillScreen()
                putAway(mode: mode)
            }
        }
    }

    /// Makes the main window fill its screen (not full screen mode, which can't be minimised).
    private static func fillScreen() {
        guard let w = mainWindow(), let f = AX.frame(of: w),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        // Window frames are measured from the top left of the main screen, NSScreen's from the bottom left.
        let centre = CGPoint(x: f.midX, y: primaryHeight - f.midY)
        guard let visible = (NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main)?.visibleFrame else { return }
        AX.setFrame(w, CGRect(x: visible.minX, y: primaryHeight - visible.maxY,
                              width: visible.width, height: visible.height))
    }

    private static func putAway(mode: String) {
        guard let bundleID = bundleID() else { return }
        Log.write("  \(mode) Claude")
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if mode == "minimise" {
            minimiseWindows(bundleID)
            // Check again in case it was busy or a window was still opening.
            for delay in [0.6, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        if isShowing(mode: "minimise") {
                            Log.write("  Claude still showing after \(delay)s, minimising again")
                            minimiseWindows(bundleID)
                        }
                    }
                }
            }
            return
        }
        for app in apps {
            if mode == "quit" { app.terminate() } else { app.hide() }
        }
        guard mode == "hide" else { return }
        // Claude doesn't always take the first hide (e.g. while it's busy): check and hide again,
        // through Accessibility if need be.
        for delay in [0.6, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    for app in apps where !app.isTerminated && !app.isHidden {
                        Log.write("  Claude still showing after \(delay)s, hiding again")
                        if !app.hide() {
                            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                                         kAXHiddenAttribute as CFString, kCFBooleanTrue)
                        }
                    }
                }
            }
        }
    }

    /// Whether Claude is on screen: not hidden, and for `minimise` with a window not minimised.
    static func isShowing(mode: String = "hide") -> Bool {
        guard let id = bundleID() else { return false }
        let visible = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { !$0.isTerminated && !$0.isHidden }
        guard visible, mode == "minimise" else { return visible }
        return AppWindows.all(id).contains { !AX.isMinimized($0) }
    }

    private static func minimiseWindows(_ bundleID: String) {
        AppWindows.all(bundleID).filter { !AX.isMinimized($0) }.forEach { AX.setMinimized($0, true) }
    }

    /// Brings back windows minimised when the project closed (opening a link doesn't always).
    static func restoreMinimised() {
        guard let id = bundleID() else { return }
        AppWindows.all(id).filter(AX.isMinimized).forEach { AX.setMinimized($0, false) }
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

    /// Returns whether the window was found.
    @discardableResult
    static func setBounds(windowName: String, _ r: CGRect) -> Bool {
        guard isRunning, !windowName.isEmpty else { return false }
        let l = Int(r.minX.rounded()), t = Int(r.minY.rounded())
        let rt = Int(r.maxX.rounded()), b = Int(r.maxY.rounded())
        let script = """
        tell application "\(appName)"
            repeat with w in windows
                try
                    if (given name of w) is "\(escape(windowName))" then
                        set minimized of w to false
                        if bounds of w is not {\(l), \(t), \(rt), \(b)} then set bounds of w to {\(l), \(t), \(rt), \(b)}
                        return true
                    end if
                end try
            end repeat
        end tell
        return false
        """
        return AppleScriptRunner.result(script)?.booleanValue ?? false
    }

    /// The Brave window you're in (front-most, not minimised), for "New Project from What's Open".
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
        Log.write("  minimise Brave window \(windowName)")
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

    static func escape(_ s: String) -> String {
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

    static func setMinimized(_ window: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Returns false if the window was already there.
    @discardableResult
    static func setFrame(_ window: AXUIElement, _ rect: CGRect) -> Bool {
        let wasMinimised = isMinimized(window)
        if !wasMinimised, let now = frame(of: window),
           abs(now.minX - rect.minX) < 2, abs(now.minY - rect.minY) < 2,
           abs(now.width - rect.width) < 2, abs(now.height - rect.height) < 2 { return false }
        if wasMinimised { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        var pos = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        // Size, move, then size again: some apps clamp the size until the window is on the right screen.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        // Bring back a window that was minimised (e.g. one of several Terminal windows).
        if wasMinimised { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        return true
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

    /// Addresses of the web pages inside a window (for Electron apps such as Claude).
    static func webAreaURLs(in window: AXUIElement) -> [URL] {
        var urls: [URL] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
                   let url = value as? URL {
                    urls.append(url)
                }
            }
            guard depth < 30 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        return urls
    }

    /// e.g. "Microsoft Word 'Interim Report'", for the log.
    static func describe(_ window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return "\(app) '\(string(window, kAXTitleAttribute) ?? "")'"
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
    /// Seconds after the first try to look again, for windows that appear as others close
    /// (closing one Preview tab brings the next one forward).
    private static let retryDelays: [Double] = [0.7, 1.5, 3]

    static func close(files: [String]) {
        guard AX.ensureTrusted() else {
            Alerts.show("Accessibility permission needed",
                        "To close only this project's windows, allow Project Launcher in System Settings > Privacy & Security > Accessibility, then try again.")
            return
        }
        let seen = Seen()
        closeOfficeDocuments(files, seen)
        closeWithScripting(files, seen)
        pressAll(files, seen, pass: "0s")
        for (i, delay) in retryDelays.enumerated() {
            let last = i == retryDelays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    pressAll(files, seen, pass: "\(delay)s")
                    if last { closeOfficeLeftovers(files, skipping: seen.paths) }
                }
            }
        }
    }

    /// What happened during one close: which files have had their window's close button pressed,
    /// and every file that had a visible window at any point.
    private final class Seen {
        var pressed: Set<String> = []
        var paths: Set<String> = []
        /// Files an app was asked to close itself. Their windows get a moment before any press.
        var scripted: Set<String> = []
    }

    /// Presses close on each matching window, leaving alone any that are asking to save.
    /// Each file is only pressed once. Word can take a few seconds to close a OneDrive file,
    /// leaving its window up meanwhile, and pressing that window again brings it back.
    /// (Checked by file, not window: Word hands out a new window reference each time.
    /// Closing one Preview tab brings the next one, a different file, forward to be pressed.)
    private static func pressAll(_ files: [String], _ seen: Seen, pass: String) {
        let found = AX.documentWindows(files: files)
        if found.isEmpty { Log.write("  [\(pass)] no matching windows") }
        for item in found {
            seen.paths.insert(item.path)
            let what = "  [\(pass)] \(AX.describe(item.window)) for \((item.path as NSString).lastPathComponent)"
            if AX.hasSheet(item.window) {
                Log.write(what + ": skipped, showing a sheet")
            } else if pass == "0s" && seen.scripted.contains(item.path) {
                Log.write(what + ": left for the app to close")
            } else if seen.pressed.contains(item.path) {
                Log.write(what + ": skipped, already pressed")
            } else {
                Log.write(what + ": pressed close")
                AX.pressClose(item.window)
                seen.pressed.insert(item.path)
            }
        }
    }

    /// Word, Excel and PowerPoint documents are closed by asking the app itself, not by pressing
    /// the window's close button: on some Macs Word closes the document after a press but leaves
    /// its empty window stuck on screen. Marks them as handled so they aren't pressed too.
    private static func closeOfficeDocuments(_ files: [String], _ seen: Seen) {
        var byPath: [String: String] = [:]
        for f in files { byPath[URL(fileURLWithPath: expandPath(f)).resolvingSymlinksInPath().path] = f }
        let matches = Office.openDocuments().filter {
            byPath[URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path] != nil
        }
        guard !matches.isEmpty else { return }
        Log.write("  [0s] asking Office to close: \(matches.map(\.name))")
        Office.close(matches)
        for doc in matches {
            if let f = byPath[URL(fileURLWithPath: doc.path).resolvingSymlinksInPath().path] {
                seen.pressed.insert(f)
                seen.paths.insert(f)
            }
        }
    }

    /// Asks scriptable apps (Preview, TextEdit and most of Apple's apps) to close the project's
    /// documents by path. Closes every one, including Preview documents in background tabs,
    /// the way the app normally would (unsaved work still prompts). Apps that can't do this
    /// fall through to the close-button press a moment later.
    private static func closeWithScripting(_ files: [String], _ seen: Seen) {
        let docs = files.filter { !seen.pressed.contains($0) }
        guard !docs.isEmpty else { return }

        // Which app has each file: its default app, plus any app showing it in a window.
        var byApp: [String: Set<String>] = [:]
        for f in docs {
            let url = URL(fileURLWithPath: expandPath(f)).resolvingSymlinksInPath()
            if let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
               let id = Bundle(url: appURL)?.bundleIdentifier {
                byApp[id, default: []].insert(f)
            }
        }
        for item in AX.documentWindows(files: docs) {
            var pid: pid_t = 0
            AXUIElementGetPid(item.window, &pid)
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                byApp[id, default: []].insert(item.path)
            }
        }

        for (id, appFiles) in byApp {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                  Scripting.isScriptable(app) else { continue }
            let paths = appFiles.map { URL(fileURLWithPath: expandPath($0)).resolvingSymlinksInPath().path }
            Log.write("  [0s] asking \(app.localizedName ?? id) to close: \(paths.map { ($0 as NSString).lastPathComponent })")
            Scripting.closeDocuments(appID: id, paths: paths)
            seen.scripted.formUnion(appFiles)
        }
    }

    /// Word/Excel/PowerPoint documents still open that never had a visible window during this close
    /// (e.g. full screen in another Space). Documents whose window already closed are skipped:
    /// Office can keep listing a OneDrive file while it uploads, and closing it again
    /// brings the window back blank.
    private static func closeOfficeLeftovers(_ files: [String], skipping seen: Set<String>) {
        let wanted = Set(files.filter { !seen.contains($0) }.map {
            URL(fileURLWithPath: expandPath($0)).resolvingSymlinksInPath().path
        })
        let open = Office.openDocuments()
        Log.write("  [office] open in Office: \(open.map(\.name)); already handled: \(seen.map { ($0 as NSString).lastPathComponent })")
        let leftovers = open.filter {
            wanted.contains(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path)
        }
        if !leftovers.isEmpty {
            Log.write("  [office] closing via AppleScript: \(leftovers.map(\.name))")
            Office.close(leftovers)
        }
    }
}

// MARK: - Checking that opening or closing worked

@MainActor
enum Verify {
    /// Things that should have opened but aren't there.
    static func afterOpen(_ p: Project) -> [Issue] {
        var issues: [Issue] = []
        let docs = p.files.filter { wholeAppBundleID($0) == nil && FileManager.default.fileExists(atPath: expandPath($0)) }
        let open = openDocuments(docs)
        for f in docs where !open.contains(f) {
            issues.append(Issue(text: "\(name(f)) didn't open"))
        }
        for appID in Set(p.files.compactMap(wholeAppBundleID)) where !isRunning(appID) {
            issues.append(Issue(text: "\(appName(appID)) isn't running"))
        }
        for brave in p.braveWindowNames.map({ $0.trimmingCharacters(in: .whitespaces) })
        where !brave.isEmpty && Brave.bounds(windowName: brave) == nil {
            issues.append(Issue(text: "Brave window \"\(brave)\" not found"))
        }
        if !p.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty,
           let id = ClaudeApp.bundleID(), !isRunning(id) {
            issues.append(Issue(text: "Claude isn't running"))
        }
        return issues
    }

    /// Things that should have closed but are still there. Windows asking to save don't count.
    static func afterClose(_ p: Project, keepRunning: Set<String>) -> [Issue] {
        var issues: [Issue] = []
        let docs = p.files.filter { wholeAppBundleID($0) == nil }
        let waiting = Set(AX.documentWindows(files: docs).filter { AX.hasSheet($0.window) }.map(\.path))
        for f in openDocuments(docs) where !waiting.contains(f) {
            let app = appBundleID(f)
            issues.append(Issue(text: "\(name(f)) is still open",
                                stuckApp: app.map(officeAppIDs.contains) == true ? app : nil))
        }
        var quitApps = Set(p.files.filter { wholeAppBundleID($0) != nil && !p.hideAppsOnClose.contains($0)
                                              && !p.minimiseAppsOnClose.contains($0) }
            .compactMap(wholeAppBundleID))
        quitApps.formUnion(p.quitAppsOnClose.filter { p.files.contains($0) }.compactMap(appBundleID))
        for appID in quitApps.subtracting(keepRunning) where isRunning(appID) {
            issues.append(Issue(text: "\(appName(appID)) is still running (it may be asking to save)"))
        }
        if !p.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty,
           let id = ClaudeApp.bundleID(), !keepRunning.contains(id) {
            if (p.claudeOnClose == "hide" || p.claudeOnClose == "minimise") && ClaudeApp.isShowing(mode: p.claudeOnClose) {
                issues.append(Issue(text: "Claude is still showing"))
            } else if p.claudeOnClose == "quit" && isRunning(id) {
                issues.append(Issue(text: "Claude is still running"))
            }
        }
        return issues
    }

    /// Which of these files are open anywhere: in a window, a Preview tab, or Office.
    private static func openDocuments(_ files: [String]) -> Set<String> {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: expandPath(path)).resolvingSymlinksInPath().path
        }
        var open = Set(AX.documentWindows(files: files).map(\.path))
        let elsewhere = Set((Office.openDocumentPaths() + Scripting.previewDocumentPaths()).map(resolved))
        for f in files where elsewhere.contains(resolved(f)) { open.insert(f) }
        return open
    }

    private static func isRunning(_ appID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: appID).contains { !$0.isTerminated }
    }

    private static func appName(_ appID: String) -> String {
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID)
                .map { FileManager.default.displayName(atPath: $0.path) } ?? appID
        return name.hasPrefix("MATLAB") ? "MATLAB" : (name as NSString).deletingPathExtension
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }
}

// MARK: - Closing documents through an app's own scripting

@MainActor
enum Scripting {
    /// Apps handled elsewhere: Office by name (see Office), Brave and Claude aren't documents.
    private static let skip: Set<String> = [
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", Brave.bundleID,
    ]

    /// Every document open in Preview, including ones in background tabs.
    static func previewDocumentPaths() -> [String] {
        let id = "com.apple.Preview"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let r = AppleScriptRunner.result("""
              tell application id "\(id)"
                  try
                      return path of every document
                  end try
              end tell
              return {}
              """), r.numberOfItems > 0 else { return [] }
        return (1...r.numberOfItems).compactMap { r.atIndex($0)?.stringValue }
    }

    static func isScriptable(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier, !skip.contains(id),
              let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
        let flag = info["NSAppleScriptEnabled"]
        return (flag as? Bool) == true || (flag as? String)?.lowercased() == "yes"
    }

    /// "close (every document whose path is ...) saving ask", sent without waiting for a reply
    /// so a save prompt can't freeze Project Launcher.
    static func closeDocuments(appID: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        let condition = paths.map { "path is \"\(escape($0))\"" }.joined(separator: " or ")
        AppleScriptRunner.result("""
        ignoring application responses
            tell application id "\(appID)"
                try
                    close (every document whose \(condition)) saving ask
                end try
            end tell
        end ignoring
        """)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Log (~/Library/Logs/ProjectLauncher.log)

/// A plain-text record of what opening and closing did, for tracking down problems.
@MainActor
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ProjectLauncher.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        let fm = FileManager.default
        // Keep it small: start afresh after 1 MB, keeping the previous one.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Alerts

@MainActor
enum Alerts {
    /// OK/Cancel question. True if OK was chosen.
    static func confirm(_ title: String, _ message: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Like confirm, with a tick box for each app (ticked unless it's an everyday app).
    /// Returns the ticked apps, or nil if cancelled.
    static func confirm(_ title: String, _ message: String, ok: String, apps: [String]) -> [String]? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        let boxes = apps.map { path -> NSButton in
            let id = Bundle(url: URL(fileURLWithPath: expandPath(path)))?.bundleIdentifier ?? ""
            let box = NSButton(checkboxWithTitle: appDisplayName(id), target: nil, action: nil)
            box.state = Capture.everydayApps.contains(id) ? .off : .on
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 280, height: stack.fittingSize.height))
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return zip(apps, boxes).filter { $0.1.state == .on }.map(\.0)
    }

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
