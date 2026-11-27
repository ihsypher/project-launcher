import AppKit

// MARK: - Screen setups

/// Identifies which screens are connected, e.g. "Built-in Retina Display 1512x982"
/// or "Built-in Retina Display 1512x982 + DELL U2720Q 2560x1440".
/// Each project keeps one window layout per screen setup.
///
/// Desks with the same kind of screens count as one setup: at a shared desk the monitor can be
/// a different model, size or arrangement each time. If these exact screens have no layout, one
/// saved for the laptop plus the same number of screens from the same maker (e.g. any HP) is
/// used, and every window is moved onto the matching screen at the same place relative to it.
@MainActor
enum ScreenSetup {
    static func currentKey() -> String {
        NSScreen.screens
            .map { "\($0.localizedName) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            .sorted()
            .joined(separator: " + ")
    }

    /// Every setup with a saved layout in some project (kept up to date by ProjectStore).
    static var savedKeys: Set<String> = []

    /// The setup these screens count as: themselves if they have a layout or a name, otherwise
    /// a known setup of the same kind (preferring one with the same screen sizes), otherwise new.
    static func activeKey() -> String {
        let current = currentKey()
        let known = savedKeys.union(names.keys)
        if known.contains(current) { return current }
        return similar(to: current, among: known).first ?? current
    }

    /// Known setups of the same kind as `key`, best match first.
    private static func similar(to key: String, among keys: Set<String>) -> [String] {
        let kind = self.kind(key)
        let sizes = Set(parts(key).map(\.size))
        return keys.filter { $0 != key && self.kind($0) == kind }.sorted { a, b in
            let sa = Set(parts(a).map(\.size)) == sizes, sb = Set(parts(b).map(\.size)) == sizes
            if sa != sb { return sa }
            let na = name(a) != nil, nb = name(b) != nil
            if na != nb { return na }
            return a < b
        }
    }

    /// "Built-in Retina Display 1512x982" -> name and size.
    private static func parts(_ key: String) -> [(name: String, size: String)] {
        key.components(separatedBy: " + ").map { part in
            var words = part.components(separatedBy: " ")
            let size = words.count > 1 ? words.removeLast() : ""
            return (words.joined(separator: " "), size)
        }
    }

    /// What kind of setup: whether the laptop screen is on, and the maker of each other screen
    /// (the first word of its name, e.g. "HP"), so "HP E24 G4" and "HP E243i" are alike.
    private static func kind(_ key: String) -> String {
        let screens = parts(key).map(\.name)
        let builtIn = screens.filter { $0.contains("Built-in") }.count
        let makers = screens.filter { !$0.contains("Built-in") }
            .map { $0.components(separatedBy: " ").first?.lowercased() ?? "" }.sorted()
        return "\(builtIn)|" + makers.joined(separator: ",")
    }

    // MARK: Where the screens were

    /// A screen's place, in window coordinates (top left of the main screen is 0,0).
    struct Screen: Codable {
        var name: String
        var x: Double, y: Double, w: Double, h: Double
        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
        var builtIn: Bool { name.contains("Built-in") }
    }

    static func currentScreens() -> [Screen] {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { s in
            Screen(name: s.localizedName, x: s.frame.minX, y: mainHeight - s.frame.maxY,
                   w: s.frame.width, h: s.frame.height)
        }
    }

    private static let geometryKey = "screenSetupGeometry"

    /// Where the screens were when a layout was last saved for this setup.
    private static func geometry(_ key: String) -> [Screen]? {
        guard let data = UserDefaults.standard.data(forKey: geometryKey),
              let all = try? JSONDecoder().decode([String: [Screen]].self, from: data) else { return nil }
        return all[key]
    }

    /// Notes where the screens are now, for a layout just saved under `key`.
    static func remember(_ key: String) {
        var all: [String: [Screen]] = [:]
        if let data = UserDefaults.standard.data(forKey: geometryKey),
           let decoded = try? JSONDecoder().decode([String: [Screen]].self, from: data) { all = decoded }
        all[key] = currentScreens()
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: geometryKey) }
    }

    /// The project's layout for the screens connected now, moved to where those screens are:
    /// this setup's own, or else one from a setup of the same kind.
    static func layout(for p: Project) -> [SavedFrame] {
        let key = activeKey()
        let candidates = [key] + similar(to: key, among: Set(p.layouts.keys))
        guard let from = candidates.first(where: { p.layouts[$0]?.isEmpty == false }),
              let frames = p.layouts[from] else { return [] }
        return translate(frames, from: geometry(from))
    }

    /// Moves frames saved with the screens at `old` onto the screens connected now: each onto
    /// its screen's counterpart (same screen, else the laptop for the laptop, else left to right),
    /// at the same place relative to it, scaled if the size differs, and kept on screen.
    static func translate(_ frames: [SavedFrame], from old: [Screen]?) -> [SavedFrame] {
        let now = currentScreens()
        guard !now.isEmpty else { return frames }
        let pairs = old.map { pair($0, now) } ?? [:]
        return frames.map { f in
            var r = f.rect
            if let old, let i = screenIndex(for: r, in: old.map(\.rect)) {
                let a = old[i], b = pairs[i] ?? now[0]
                let sx = b.w / a.w, sy = b.h / a.h
                r = CGRect(x: b.x + (r.minX - a.x) * sx, y: b.y + (r.minY - a.y) * sy,
                           width: r.width * sx, height: r.height * sy)
            }
            var out = f
            let fitted = fit(r, in: now.map(\.rect))
            out.x = Double(fitted.minX); out.y = Double(fitted.minY)
            out.w = Double(fitted.width); out.h = Double(fitted.height)
            return out
        }
    }

    /// Which new screen stands in for each old one.
    private static func pair(_ old: [Screen], _ now: [Screen]) -> [Int: Screen] {
        var result: [Int: Screen] = [:]
        var left = Array(now.indices)
        func take(_ i: Int, where match: (Screen) -> Bool) {
            guard result[i] == nil, let j = left.firstIndex(where: { match(now[$0]) }) else { return }
            result[i] = now[left.remove(at: j)]
        }
        for i in old.indices { take(i) { $0.name == old[i].name && $0.w == old[i].w && $0.h == old[i].h } }
        for i in old.indices { take(i) { $0.name == old[i].name } }
        for i in old.indices where old[i].builtIn { take(i) { $0.builtIn } }
        // The rest in order from left to right (then top to bottom).
        let order: (Screen, Screen) -> Bool = { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        let oldRest = old.indices.filter { result[$0] == nil }.sorted { order(old[$0], old[$1]) }
        left.sort { order(now[$0], now[$1]) }
        for (i, j) in zip(oldRest, left) { result[i] = now[j] }
        return result
    }

    /// The screen a window is on: the one holding its centre, else the one it overlaps most.
    private static func screenIndex(for r: CGRect, in screens: [CGRect]) -> Int? {
        let centre = CGPoint(x: r.midX, y: r.midY)
        if let i = screens.firstIndex(where: { $0.contains(centre) }) { return i }
        let overlaps = screens.map { $0.intersection(r) }.map { $0.isNull ? 0 : $0.width * $0.height }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 else { return nil }
        return best
    }

    /// Keeps a window on one of the screens: no bigger than it, and not hanging off its edges.
    private static func fit(_ r: CGRect, in screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return r }
        let s = screenIndex(for: r, in: screens).map { screens[$0] } ?? screens[0]
        let w = min(r.width, s.width), h = min(r.height, s.height)
        let x = min(max(r.minX, s.minX), s.maxX - w), y = min(max(r.minY, s.minY), s.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    // MARK: Names

    static let namesKey = "screenSetupNames"

    private static var names: [String: String] {
        (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]).filter { !$0.value.isEmpty }
    }

    /// The name you gave a screen setup, e.g. "Laptop" or "Desk".
    static func name(_ key: String) -> String? {
        names[key]
    }

    static func setName(_ name: String, for key: String) {
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[key] = name.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    /// Drops a setup's name and where its screens were.
    static func forget(_ key: String) {
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        names[key] = nil
        UserDefaults.standard.set(names, forKey: namesKey)
        if let data = UserDefaults.standard.data(forKey: geometryKey),
           var all = try? JSONDecoder().decode([String: [Screen]].self, from: data) {
            all[key] = nil
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: geometryKey) }
        }
    }

    /// Its name, or a description if it hasn't got one.
    static func label(_ key: String) -> String {
        name(key) ?? (key.contains(" + ") ? "\(key.components(separatedBy: " + ").count) screens" : "Single screen")
    }

    /// Asks for a name for the screens connected now, the first time a layout is saved for them.
    static func nameCurrentIfNeeded() {
        let key = activeKey()
        guard name(key) == nil else { return }
        let laptopOnly = !key.contains(" + ") && key.contains("Built-in")
        if let name = Alerts.askText("Name these screens",
                                     "Layouts are saved separately for each screen setup, and chosen automatically when you open a project. A name helps you tell them apart.\n\nScreens: \(key)",
                                     suggestion: laptopOnly ? "Laptop" : "Desk", okTitle: "Save", cancelTitle: "Skip") {
            setName(name, for: key)
        }
    }

    /// Every screen setup with a saved layout, plus the current one.
    static func known(in projects: [Project]) -> [String] {
        var keys = Set(projects.flatMap { $0.layouts.keys })
        keys.insert(activeKey())
        return keys.sorted { label($0) < label($1) }
    }
}

// MARK: - Saving and restoring window positions

@MainActor
enum Layouts {
    /// Records where this project's windows are right now.
    /// `onlyKnown`: for saving automatically on close, skip an app whose saved window has gone
    /// (rather than taking whichever is in front) and a minimised Claude.
    static func capture(_ p: Project, onlyKnown: Bool = false) -> [SavedFrame] {
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
        let before = ScreenSetup.layout(for: p)
        for path in p.files where isApp(path) {
            guard let id = Bundle(url: URL(fileURLWithPath: expandPath(path)))?.bundleIdentifier else { continue }
            let saved = before.first { $0.kind == "app" && $0.key == path } ?? AppWindows.identity(of: path, in: p)
            let found = saved.flatMap { AppWindows.find(id, $0, fallback: false) }
            if onlyKnown && saved != nil && found == nil { continue }
            guard let w = found ?? AppWindows.front(id), !AX.isMinimized(w), let r = AX.frame(of: w) else { continue }
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
           let w = ClaudeApp.mainWindow(), !(onlyKnown && AX.isMinimized(w)), let r = AX.frame(of: w) {
            frames.append(SavedFrame(kind: "claude", key: "claude", rect: r))
        }
        return frames
    }

    /// Moves windows back to their saved positions. Returns the frames whose window was
    /// found (moved, or already in place), so they needn't be tried again.
    @discardableResult
    static func apply(_ frames: [SavedFrame]) -> Set<SavedFrame> {
        guard AX.ensureTrusted(prompt: false) else { return [] }
        var placed: Set<SavedFrame> = []

        let fileFrames = frames.filter { $0.kind == "file" }
        if !fileFrames.isEmpty {
            for item in AX.documentWindows(files: fileFrames.map { $0.key }) {
                if let f = fileFrames.first(where: { $0.key == item.path }) {
                    if AX.setFrame(item.window, f.rect) { Log.write("  [layout] move \(AX.describe(item.window))") }
                    placed.insert(f)
                }
            }
        }

        for f in frames {
            switch f.kind {
            case "app":
                if let id = Bundle(url: URL(fileURLWithPath: expandPath(f.key)))?.bundleIdentifier,
                   let w = AppWindows.find(id, f, fallback: true) {
                    AX.setFrame(w, f.rect)
                    placed.insert(f)
                }
            case "brave":
                if Brave.setBounds(windowName: f.key, f.rect) { placed.insert(f) }
            case "claude":
                if let id = ClaudeApp.bundleID(), let w = AppWindows.all(id).first {
                    AX.setFrame(w, f.rect)
                    placed.insert(f)
                }
            default:
                break
            }
        }
        return placed
    }

    /// Windows take a moment to appear after opening (Word can take 5s+ for a OneDrive file),
    /// so each is placed as soon as it's there: checking every 0.3-0.5s for the first 4s, then
    /// every second up to 9s. Then everything is checked once more 1.5s later in case an app
    /// moved its own window while loading. Stops if the project is closed again in the meantime.
    static func applySoon(_ frames: [SavedFrame], while stillOpen: @escaping @MainActor () -> Bool) {
        var waiting = Set(frames)
        func placeWaiting() {
            guard !waiting.isEmpty, stillOpen() else { return }
            waiting.subtract(apply(Array(waiting)))
        }
        // Windows the apps create (e.g. Word opening a document on another screen) are moved
        // the moment they appear, and once more just after, in case the title came a bit later.
        // The timer below catches anything this misses.
        let apps = Set(frames.compactMap { f -> String? in
            switch f.kind {
            case "file": return appBundleID(f.key)
            case "app": return Bundle(url: URL(fileURLWithPath: expandPath(f.key)))?.bundleIdentifier
            default: return nil
            }
        })
        let watch = NewWindowWatch(bundleIDs: apps) {
            placeWaiting()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { placeWaiting() } }
        }
        Task { @MainActor in
            defer { watch.stop() }
            let delays = [0.3, 0.3, 0.4, 0.5, 0.5, 0.5, 0.5, 0.5, 1, 1, 1, 1, 1]
            for delay in delays where !waiting.isEmpty {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard stillOpen() else { return }
                placeWaiting()
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard stillOpen() else { return }
            apply(frames.filter { !waiting.contains($0) })
        }
    }
}

/// Calls back whenever one of these apps creates or switches to a window, including apps
/// that start up while watching.
@MainActor
final class NewWindowWatch {
    private let bundleIDs: Set<String>
    private let onWindow: @MainActor () -> Void
    private var observers: [pid_t: AXObserver] = [:]
    private var launchWatcher: NSObjectProtocol?

    init(bundleIDs: Set<String>, onWindow: @escaping @MainActor () -> Void) {
        self.bundleIDs = bundleIDs
        self.onWindow = onWindow
        guard !bundleIDs.isEmpty, AX.ensureTrusted(prompt: false) else { return }
        for id in bundleIDs {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { watch($0.processIdentifier) }
        }
        launchWatcher = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, let id = app.bundleIdentifier, self.bundleIDs.contains(id) else { return }
                self.watch(app.processIdentifier)
            }
        }
    }

    private func watch(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let watch = Unmanaged<NewWindowWatch>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watch.onWindow() }
        }, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    func stop() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers = [:]
        if let launchWatcher { NSWorkspace.shared.notificationCenter.removeObserver(launchWatcher) }
        launchWatcher = nil
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
        if let saved = identity(of: path, in: p) { return find(bundleID, saved, fallback: false).map { [$0] } ?? [] }
        return all(bundleID)
    }

    /// Which window of an app is the project's: from the layout for these screens, or any other
    /// screen setup's if there isn't one here (the window is the same, only its position differs).
    static func identity(of path: String, in p: Project) -> SavedFrame? {
        let current = ScreenSetup.activeKey()
        let layouts = [p.layouts[current] ?? []] + p.layouts.filter { $0.key != current }.map(\.value)
        return layouts.lazy.compactMap { $0.first { $0.kind == "app" && $0.key == path && $0.title != nil } }.first
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

// MARK: - "New Project from Open Windows"

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
            if isCloudDocument(path) {
                if !paths.contains(path) { paths.append(path) }
                return
            }
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
                let recent = RecentFiles.forApp(id)
                // Everyday apps and Terminal don't show files, so their titles aren't looked up.
                let searchable = !everydayApps.contains(id) && id != Terminal.bundleID
                for w in AX.windows(pid: app.processIdentifier) where !AX.isMinimized(w) {
                    if let path = AX.documentPath(w) ?? RecentFiles.match(w, in: recent)
                        ?? (searchable ? RecentFiles.search(w, appID: id, appName: app.localizedName) : nil) { add(path) }
                }
            }
        }

        // Word, Excel and PowerPoint, asked directly in case they don't report documents above,
        // and Preview, so documents in background tabs are included too. These list every
        // document, so leave out ones whose windows are all minimised or whose app is hidden.
        let asked = Office.openDocumentPaths() + Scripting.previewDocumentPaths()
        let windows = AX.documentWindows(files: asked, everywhere: true)
        for path in asked {
            let mine = windows.filter { $0.path == path }.map(\.window)
            if !mine.isEmpty && mine.allSatisfy(AX.isMinimized) { continue }
            if let id = appBundleID(path),
               NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: \.isHidden) { continue }
            add(path)
        }

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

/// Apps whose windows don't say which file they show (no AXDocument), but which keep a list of
/// recent files: a window is matched to a recent file by its title (e.g. Bambu Studio's
/// "A1_print_plate" is ~/Downloads/A1_print_plate.3mf).
@MainActor
enum RecentFiles {
    static func forApp(_ bundleID: String) -> [String] {
        switch bundleID {
        case "com.bambulab.bambu-studio":
            return jsonList(at: "~/Library/Application Support/BambuStudio/BambuStudio.conf", key: "recent_projects")
        default:
            return []
        }
    }

    /// The recent file whose name, with or without its extension, is the window's title.
    static func match(_ window: AXUIElement, in recent: [String]) -> String? {
        guard !recent.isEmpty, var title = AX.string(window, kAXTitleAttribute)?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else { return nil }
        // An unsaved change shows as "*name" or "name*".
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "* "))
        return recent.first { path in
            let url = URL(fileURLWithPath: path)
            return (title == url.lastPathComponent || title == url.deletingPathExtension().lastPathComponent)
                && FileManager.default.fileExists(atPath: path)
        }
    }

    /// For any other app whose window doesn't say which file it shows: looks for a file named
    /// like the window's title (or part of it, e.g. "name — App") with Spotlight, in your
    /// home folder, that opens in this app by default. The most recently used one wins.
    static func search(_ window: AXUIElement, appID: String, appName: String?) -> String? {
        guard let title = AX.string(window, kAXTitleAttribute) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for name in titleCandidates(title, appName: appName) {
            let q = name.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "*", with: "\\*")
            let found = spotlight("kMDItemFSName == \"\(q)\" || kMDItemFSName == \"\(q).*\"", in: home)
                .filter { path in
                    // Not app support files, but iCloud Drive and OneDrive are fine.
                    let inLibrary = path.hasPrefix(home + "/Library/")
                        && !path.hasPrefix(home + "/Library/Mobile Documents/")
                        && !path.hasPrefix(home + "/Library/CloudStorage/")
                    return !inLibrary && !isApp(path) && opensIn(path, appID)
                }
            if let best = found.max(by: { lastUsed($0) < lastUsed($1) }) { return best }
        }
        return nil
    }

    /// The names a window title might be: all of it, then each part between separators,
    /// without unsaved-change marks, skipping the app's own name.
    private static func titleCandidates(_ title: String, appName: String?) -> [String] {
        func clean(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            for suffix in [" (Edited)", " - Edited", " — Edited", " [Read-Only]"] where t.hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count))
            }
            return t.trimmingCharacters(in: CharacterSet(charactersIn: "*• ").union(.whitespaces))
        }
        var parts = [clean(title)]
        for sep in [" — ", " – ", " - ", " | ", " : "] where title.contains(sep) {
            parts += title.components(separatedBy: sep).map(clean)
        }
        let app = appName?.lowercased()
        var seen = Set<String>()
        return parts.filter { $0.count >= 3 && $0.lowercased() != app && $0.lowercased() != "untitled" && seen.insert($0).inserted }
    }

    private static func opensIn(_ path: String, _ appID: String) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return false }
        if isFolder.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path) { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: path))
            .flatMap { Bundle(url: $0)?.bundleIdentifier } == appID
    }

    private static func lastUsed(_ path: String) -> Date {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
        return max(v?.contentAccessDate ?? .distantPast, v?.contentModificationDate ?? .distantPast)
    }

    /// Paths Spotlight finds for a query, giving up after 2 seconds.
    private static func spotlight(_ query: String, in folder: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", folder, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init).prefix(50).map { $0 }
    }

    /// The values of a JSON object inside a settings file, newest (lowest key) first.
    /// Bambu Studio puts a comment line before the JSON, so reading starts at the first "{".
    private static func jsonList(at path: String, key: String) -> [String] {
        guard let text = try? String(contentsOfFile: expandPath(path), encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let data = String(text[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json[key] as? [String: String] else { return [] }
        return list.sorted { $0.key < $1.key }.map(\.value)
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
                // A synced OneDrive file by its copy on this Mac; online-only ones by their address.
                if path.contains("://") { path = OneDrive.localPath(for: path) ?? path }
                out.append(OpenDocument(appID: app.id, collection: app.collection, path: path, name: name))
            }
        }
        return out
    }

    /// The same as openDocuments, asked in the background so a slow Office app can't freeze
    /// anything (an app that doesn't answer within 6 seconds is treated as having none open).
    /// With `files`, only the Office apps those files open in are asked, so a sleepy Excel
    /// doesn't hold up closing a Word document.
    static func openDocumentsInBackground(for files: [String]? = nil, _ done: @escaping @MainActor ([OpenDocument]) -> Void) {
        let wanted = files.map { Set($0.compactMap(appBundleID)) }
        let running = apps.filter {
            wanted?.contains($0.id) != false
                && !NSRunningApplication.runningApplications(withBundleIdentifier: $0.id).isEmpty
        }
        guard !running.isEmpty else { return done([]) }
        let parts = running.map { app in """
            set theFull to {}
            set theNames to {}
            try
                with timeout of 6 seconds
                    tell application id "\(app.id)"
                        set theFull to full name of \(app.collection)
                        set theNames to name of \(app.collection)
                    end tell
                end timeout
            end try
            -- An app with nothing open answers "missing value"; one document can come back on its own.
            if theFull is missing value then set theFull to {}
            if theNames is missing value then set theNames to {}
            if class of theFull is not list then set theFull to {theFull}
            if class of theNames is not list then set theNames to {theNames}
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
                if p is not "" and i ≤ (count of theNames) then set out to out & "\(app.id)" & tab & p & tab & ((item i of theNames) as text) & linefeed
            end repeat
            """
        }
        let script = "set out to \"\"\n" + parts.joined(separator: "\n") + "\nreturn out"
        BackgroundScript.run(script, lane: "office", timeout: 20, label: "Office documents") { output, _ in
            done(BackgroundScript.lines(output).compactMap { line in
                let f = line.components(separatedBy: "\t")
                guard f.count >= 3, let app = apps.first(where: { $0.id == f[0] }) else { return nil }
                var path = f[1]
                if path.contains("://") { path = OneDrive.localPath(for: path) ?? path }
                return OpenDocument(appID: app.id, collection: app.collection, path: path,
                                    name: f[2...].joined(separator: "\t"))
            })
        }
    }

    /// Asks Office to close these documents ("saving ask", so unsaved work still prompts).
    /// Doesn't wait for a reply, so a save prompt can't freeze Project Launcher.
    static func close(_ docs: [OpenDocument]) {
        for doc in docs {
            guard let element = apps.first(where: { $0.id == doc.appID })?.element else { continue }
            let name = doc.name.replacingOccurrences(of: "\\", with: "\\\\")
                               .replacingOccurrences(of: "\"", with: "\\\"")
            BackgroundScript.run("""
            ignoring application responses
                tell application id "\(doc.appID)"
                    try
                        close \(element) "\(name)" saving ask
                    end try
                end tell
            end ignoring
            """, lane: "office", label: "close \(doc.name)")
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
