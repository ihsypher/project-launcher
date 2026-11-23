import SwiftUI
import AppKit

struct EditorView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var showSettings = false
    /// Project or group waiting for "Delete?" to be confirmed.
    @State private var pendingDelete: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $store.editorSelection) {
                ForEach(store.activeProjects(in: nil)) { p in
                    projectRow(p)
                }
                .onMove { store.moveProjects(in: nil, from: $0, to: $1) }

                ForEach(store.groups) { g in
                    groupRow(g)
                    ForEach(store.activeProjects(in: g.id)) { p in
                        projectRow(p)
                    }
                    .onMove { store.moveProjects(in: g.id, from: $0, to: $1) }
                }

                if !store.archivedProjects.isEmpty {
                    Section("Archived") {
                        ForEach(store.archivedProjects) { p in
                            projectRow(p).opacity(0.6)
                        }
                    }
                }
            }
            .onDeleteCommand { pendingDelete = store.editorSelection }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        store.editorSelection = store.addProject(group: selectedGroupID)
                    } label: { Image(systemName: "plus") }
                    .help("New project (in the selected group, if any)")

                    Button {
                        store.editorSelection = store.addGroup()
                    } label: { Image(systemName: "folder.badge.plus") }
                    .help("New group")

                    Button {
                        pendingDelete = store.editorSelection
                    } label: { Image(systemName: "minus") }
                    .disabled(store.editorSelection == nil)
                    .help("Delete the selected project or group")

                    Spacer()

                    Button {
                        showSettings = true
                    } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = store.editorSelection, store.projects.contains(where: { $0.id == id }) {
                ProjectDetail(project: binding(for: id))
                    .id(id)
            } else if let id = store.editorSelection, store.groups.contains(where: { $0.id == id }) {
                GroupDetail(group: groupBinding(for: id))
                    .id(id)
            } else {
                Text("Select a project or group, or press + to add one")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete { delete(id) }
                pendingDelete = nil
            }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: Rows

    private func projectRow(_ p: Project) -> some View {
        HStack(spacing: 8) {
            ProjectIcon(icon: p.icon, color: p.color, size: 18)
            Text(p.name).lineLimit(1)
            Spacer()
            if store.isOpen(p) {
                Circle().fill(.green).frame(width: 6, height: 6)
                    .help("Open")
            }
        }
        .padding(.vertical, 1)
        .padding(.leading, p.groupID == nil || p.archived ? 0 : 14)
        .tag(p.id)
        .contextMenu {
            Button(store.isOpen(p) ? "Close Project" : "Open Project") { store.toggle(p) }
            Divider()
            Menu("Move to Group") {
                Button("No Group") { store.moveProject(p.id, toGroup: nil) }
                    .disabled(p.groupID == nil)
                Divider()
                ForEach(store.groups) { g in
                    Button(g.name) { store.moveProject(p.id, toGroup: g.id) }
                        .disabled(p.groupID == g.id)
                }
                Divider()
                Button("New Group…") {
                    let g = store.addGroup()
                    store.moveProject(p.id, toGroup: g)
                    store.editorSelection = g
                }
            }
            Divider()
            Button("Duplicate") { store.editorSelection = store.duplicate(p.id) }
            Button(p.archived ? "Unarchive" : "Archive") { store.setArchived(p.id, !p.archived) }
            Button("Delete Project…", role: .destructive) { pendingDelete = p.id }
        }
    }

    private func groupRow(_ g: ProjectGroup) -> some View {
        let index = store.groups.firstIndex(of: g) ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(g.name).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Text(formatDuration(store.groupTime(g.id)))
                .font(.caption).foregroundStyle(.secondary)
                .help("Total time across this group's projects")
        }
        .tag(g.id)
        .contextMenu {
            Button("New Project in Group") { store.editorSelection = store.addProject(group: g.id) }
            Divider()
            Button("Move Group Up") { store.moveGroup(g.id, by: -1) }
                .disabled(index == 0)
            Button("Move Group Down") { store.moveGroup(g.id, by: 1) }
                .disabled(index == store.groups.count - 1)
            Divider()
            Button("Delete Group…", role: .destructive) { pendingDelete = g.id }
        }
    }

    // MARK: Deleting

    private var deleteTitle: String {
        guard let id = pendingDelete else { return "Delete?" }
        if let g = store.groups.first(where: { $0.id == id }) { return "Delete the group \"\(g.name)\"?" }
        if let p = store.projects.first(where: { $0.id == id }) { return "Delete \"\(p.name)\"?" }
        return "Delete?"
    }

    private var deleteMessage: String {
        guard let id = pendingDelete else { return "" }
        if store.groups.contains(where: { $0.id == id }) {
            return "Its projects are kept and become ungrouped."
        }
        return "This removes the project's file list, links, layouts and time log from Project Launcher. The files themselves aren't touched."
    }

    /// Deletes, then selects whatever was next in the list so the selection doesn't vanish.
    private func delete(_ id: UUID) {
        let before = store.sidebarOrder()
        let index = before.firstIndex(of: id) ?? 0
        store.delete(id: id)
        let after = store.sidebarOrder()
        store.editorSelection = after.isEmpty ? nil : after[min(index, after.count - 1)]
    }

    // MARK: Bindings

    /// The selected group, or the group of the selected project.
    private var selectedGroupID: UUID? {
        guard let id = store.editorSelection else { return nil }
        if store.groups.contains(where: { $0.id == id }) { return id }
        return store.projects.first(where: { $0.id == id })?.groupID
    }

    private func groupBinding(for id: UUID) -> Binding<ProjectGroup> {
        Binding(
            get: { store.groups.first(where: { $0.id == id }) ?? ProjectGroup() },
            set: { updated in
                if let i = store.groups.firstIndex(where: { $0.id == id }) {
                    store.groups[i] = updated
                }
            }
        )
    }

    /// Binding by id (safe if the project is deleted while shown).
    private func binding(for id: UUID) -> Binding<Project> {
        Binding(
            get: { store.projects.first(where: { $0.id == id }) ?? Project() },
            set: { updated in
                if let i = store.projects.firstIndex(where: { $0.id == id }) {
                    store.projects[i] = updated
                }
            }
        )
    }
}

/// Reordering (Array.move comes from SwiftUI).
extension ProjectStore {
    /// Reorders the projects shown in one part of the sidebar (a group, or ungrouped).
    func moveProjects(in groupID: UUID?, from source: IndexSet, to destination: Int) {
        var subset = activeProjects(in: groupID)
        subset.move(fromOffsets: source, toOffset: destination)
        let ids = Set(subset.map(\.id))
        var next = subset.makeIterator()
        projects = projects.map { ids.contains($0.id) ? next.next()! : $0 }
    }

    /// Moves a project into a group (or out, with nil), at the end of it.
    func moveProject(_ id: UUID, toGroup groupID: UUID?) {
        var copy = projects
        guard let i = copy.firstIndex(where: { $0.id == id }) else { return }
        var p = copy.remove(at: i)
        p.groupID = groupID
        copy.append(p)
        projects = copy
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard groups.indices.contains(j) else { return }
        groups.swapAt(i, j)
    }

    /// Everything in the sidebar, top to bottom.
    func sidebarOrder() -> [UUID] {
        activeProjects(in: nil).map(\.id)
            + groups.flatMap { [$0.id] + activeProjects(in: $0.id).map(\.id) }
            + archivedProjects.map(\.id)
    }
}

struct GroupDetail: View {
    @EnvironmentObject var store: ProjectStore
    @Binding var group: ProjectGroup
    @FocusState private var nameFocused: Bool

    var body: some View {
        let members = store.projects(in: group.id)
        Form {
            Section {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 48, height: 48)
                        .overlay(Image(systemName: "folder.fill").font(.system(size: 22)).foregroundStyle(.secondary))
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Group", text: $group.name)
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                            .focused($nameFocused)
                        Text("\(members.count) project\(members.count == 1 ? "" : "s") · \(formatDuration(store.groupTime(group.id))) in total")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if members.isEmpty {
                    Text("No projects yet.").foregroundStyle(.secondary)
                }
                ForEach(members) { p in
                    HStack(spacing: 8) {
                        ProjectIcon(icon: p.icon, color: p.color, size: 18)
                        Text(p.name)
                        if p.archived {
                            Text("archived").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatDuration(p.timeSpent())).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.editorSelection = p.id }
                }
            } header: {
                Label("Projects", systemImage: "square.stack")
            } footer: {
                Text("Press + with the group selected, or right-click a project > Move to Group.")
            }

            Section {
                LabeledContent("Today", value: formatDuration(store.groupTime(group.id, since: Calendar.current.startOfDay(for: Date()))))
                LabeledContent("Last 7 days", value: formatDuration(store.groupTime(group.id, since: Date().addingTimeInterval(-7 * 24 * 3600))))
                LabeledContent("Total", value: formatDuration(store.groupTime(group.id)))
            } header: {
                Label("Time spent (all projects)", systemImage: "clock")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // A new group: ready to type its name.
            if group.name == ProjectGroup().name { DispatchQueue.main.async { nameFocused = true } }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProjectStore.closeOthersKey) private var closeOthers = true
    @AppStorage(RaycastScripts.enabledKey) private var raycast = true
    @AppStorage(ProjectStore.idleMinutesKey) private var idleMinutes = 10
    @AppStorage(ProjectStore.saveLayoutOnCloseKey) private var saveLayoutOnClose = true
    @AppStorage(ProjectStore.menuOrderKey) private var menuOrder = "manual"
    @State private var updateStatus: String?
    @EnvironmentObject var store: ProjectStore
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var backupStatus = Backups.lastBackupText()
    @AppStorage(ClaudeApp.freshOnCloseKey) private var claudeFresh = true
    @State private var screenNames: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Close other projects when opening one", isOn: $closeOthers)
                    Toggle("Remember window positions when closing a project", isOn: $saveLayoutOnClose)
                    Picker("Menu order", selection: $menuOrder) {
                        Text("As in Edit Projects").tag("manual")
                        Text("Most recently used").tag("recent")
                        Text("Due soonest").tag("due")
                    }
                    Picker("Pause time when away for", selection: $idleMinutes) {
                        Text("Never").tag(0)
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Toggle("Start Claude on a new chat, filling the screen, when you open it yourself after a project", isOn: $claudeFresh)
                    Toggle("Open Project Launcher at login", isOn: Binding(
                        get: { openAtLogin },
                        set: { LoginItem.set($0); openAtLogin = LoginItem.isEnabled }
                    ))
                } header: {
                    Label("General", systemImage: "gearshape")
                } footer: {
                    Text("Hold Option when opening a project to keep the others open. Time stops counting while you're away and restarts when you're back.")
                }

                Section {
                    Toggle("Raycast commands", isOn: Binding(
                        get: { raycast },
                        set: { raycast = $0; RaycastScripts.sync(projects: store.projects, groups: store.groups, force: true) }
                    ))
                    if raycast {
                        HStack {
                            Button("Show Folder") {
                                RaycastScripts.sync(projects: store.projects, groups: store.groups, force: true)
                                NSWorkspace.shared.activateFileViewerSelecting([RaycastScripts.folder])
                            }
                            Button("Copy Folder Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(RaycastScripts.folder.path, forType: .string)
                            }
                            Spacer()
                        }
                    }
                } header: {
                    Label("Raycast", systemImage: "magnifyingglass")
                } footer: {
                    Text("Search any project in Raycast to open or close it. Setup once: Raycast Settings > Extensions > + > Add Script Directory, then Cmd-Shift-G and paste the path.")
                }

                Section {
                    ForEach(ScreenSetup.known(in: store.projects), id: \.self) { key in
                        TextField(text: Binding(
                            get: { screenNames[key] ?? ScreenSetup.name(key) ?? "" },
                            set: { screenNames[key] = $0; ScreenSetup.setName($0, for: key) }
                        ), prompt: Text(ScreenSetup.label(key))) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key == ScreenSetup.currentKey() ? "Connected now" : "Screen setup")
                                Text(key).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Label("Screen setups", systemImage: "display.2")
                } footer: {
                    Text("Each project keeps a window layout per screen setup, picked automatically when you open it. Name them (e.g. Laptop, Desk) to tell them apart.")
                }

                Section {
                    HStack {
                        Button("Back Up Now") {
                            store.flushSave()
                            Backups.make()
                            backupStatus = Backups.lastBackupText()
                        }
                        Button("Show Backups") {
                            if Backups.all().isEmpty { Backups.make() }
                            NSWorkspace.shared.activateFileViewerSelecting([Backups.folder])
                        }
                        Button("Restore…") { restore() }
                        Spacer()
                        Text(backupStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Backups", systemImage: "clock.arrow.circlepath")
                } footer: {
                    Text(Backups.isInICloud
                         ? "Your projects, groups and time are backed up daily to iCloud Drive > Project Launcher Backups (last \(Backups.keep) kept), so they're safe if you reinstall or get a new Mac."
                         : "Your projects, groups and time are backed up daily (last \(Backups.keep) kept). Turn on iCloud Drive to keep them off this Mac too.")
                }

                Section {
                    HStack {
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        Spacer()
                        if store.updateAvailable {
                            Button("Install Update…") { Updater.run() }
                        } else {
                            if let updateStatus {
                                Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Check for Updates") {
                                updateStatus = "Checking…"
                                Updater.checkForUpdates { available in
                                    store.setUpdateAvailable(available)
                                    updateStatus = available ? nil : "Up to date"
                                }
                            }
                        }
                    }
                } header: {
                    Label("Updates", systemImage: "arrow.down.circle")
                } footer: {
                    Text("Checks GitHub every 4 hours too. When there's a new version, Install Update… also appears in the menu.")
                }

                Section {
                    HStack {
                        Button("Show Log") {
                            if !FileManager.default.fileExists(atPath: Log.url.path) {
                                Log.write("Log started")
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([Log.url])
                        }
                        Button("Clear Log") { Log.clear() }
                        Spacer()
                    }
                } header: {
                    Label("Troubleshooting", systemImage: "stethoscope")
                } footer: {
                    Text("A record of what each open and close did. Useful if something goes wrong.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 720)
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Backups.folder
        panel.prompt = "Restore"
        panel.message = "Choose a backup to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.restoreBackup(from: url)
        backupStatus = Backups.lastBackupText()
    }
}

struct ProjectDetail: View {
    @EnvironmentObject var store: ProjectStore
    @Binding var project: Project
    @State private var newURL = ""
    @State private var braveNames: [String] = []
    @State private var braveMessage: String?
    @State private var layoutMessage: String?
    @State private var confirmReset = false
    @State private var showIconPicker = false
    @AppStorage("showAdvanced") private var showAdvanced = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Button { showIconPicker = true } label: {
                        ProjectIcon(icon: project.icon, color: project.color, size: 48)
                    }
                    .buttonStyle(.plain)
                    .help("Choose an icon and colour")
                    .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                        IconPicker(icon: $project.icon, color: $project.color)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Project", text: $project.name)
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                            .focused($nameFocused)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Group", selection: $project.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.groups) { g in
                        Text(g.name).tag(UUID?.some(g.id))
                    }
                }
                Toggle("Archived", isOn: Binding(
                    get: { project.archived },
                    set: { store.setArchived(project.id, $0) }
                ))
                .help("Hidden from the menu and Raycast. Time still counts.")
                Toggle("Deadline", isOn: hasDeadline)
                if project.deadline != nil {
                    DatePicker("Due", selection: deadlineDate, displayedComponents: [.date, .hourAndMinute])
                    Text(deadlineText(project.deadline ?? Date()).capitalizedFirst)
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Label("Details", systemImage: "info.circle")
            }

            Section {
                ForEach(project.files, id: \.self) { path in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: expandPath(path)))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text((path as NSString).lastPathComponent)
                        if !FileManager.default.fileExists(atPath: expandPath(path)) {
                            Text("missing").font(.caption).foregroundStyle(.red)
                            Button("Find…") { relink(path) }
                                .controlSize(.small)
                                .help("Find where this file has moved to")
                        }
                        Spacer()
                        if isApp(path) || closesWholeApp(path) {
                            Picker("On close", selection: appCloseMode(for: path)) {
                                Text(closesWholeApp(path) ? "Quit \(appName(for: path))" : "Quit").tag("quit")
                                Text(closesWholeApp(path) ? "Hide \(appName(for: path))" : "Hide").tag("hide")
                                Text("Minimise").tag("minimise")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help(closesWholeApp(path)
                                  ? "\(appName(for: path)) can't close one file, so it quits, hides or minimises instead"
                                  : "Quit the app, hide all its windows, or minimise just this project's window")
                        } else if appBundleID(path) != nil {
                            Picker("On close", selection: documentCloseMode(for: path)) {
                                Text("Close File").tag("file")
                                Text("Minimise").tag("minimise")
                                Text("Quit \(appName(for: path).replacingOccurrences(of: "Microsoft ", with: ""))").tag("quit")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help("Close just this file, minimise its window (it stays open), or close it and quit the app too (unless another open project uses it)")
                        }
                        Button {
                            project.files.removeAll { $0 == path }
                            project.hideAppsOnClose.removeAll { $0 == path }
                            project.minimiseAppsOnClose.removeAll { $0 == path }
                            project.quitAppsOnClose.removeAll { $0 == path }
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                    .help(path)
                }
                HStack {
                    Button("Add Files…", action: addFiles)
                    Button("Add Open Windows…") { store.updateFromOpenWindows(project.id) }
                        .help("Add documents open right now and save the layout")
                }
            } header: {
                Label("Files", systemImage: "doc.on.doc")
            } footer: {
                Text("Drag files here, or use Add Files. They open in their usual app and close with the project. Apps (and MATLAB, which can't close one file) quit, hide or minimise instead.")
            }

            Section {
                TextField("https://claude.ai/chat/...", text: $project.claudeLink)
                if !project.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty
                    && ClaudeApp.deepLink(from: project.claudeLink) == nil {
                    Text("This doesn't look like a claude.ai chat or project link.")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("When the project closes", selection: $project.claudeOnClose) {
                    Text("Minimise Claude").tag("minimise")
                    Text("Hide Claude").tag("hide")
                    Text("Quit Claude").tag("quit")
                    Text("Leave it").tag("leave")
                }
            } header: {
                Label("Claude chat or project (optional)", systemImage: "bubble.left.and.bubble.right")
            } footer: {
                Text("Paste a claude.ai chat or project address. It opens in the Claude app. Share links won't work.")
            }

            Section {
                if project.braveWindowNames.isEmpty {
                    Text("No Brave windows yet.").foregroundStyle(.secondary)
                }
                ForEach(project.braveWindowNames, id: \.self) { name in
                    HStack {
                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                        Text(name)
                        Spacer()
                        if !braveNames.isEmpty && !braveNames.contains(name) {
                            Text("not open").font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            project.braveWindowNames.removeAll { $0 == name }
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add Window") {
                        let available = braveNames.filter { !project.braveWindowNames.contains($0) }
                        if available.isEmpty {
                            Text("No other named windows")
                        }
                        ForEach(available, id: \.self) { name in
                            Button(name) { project.braveWindowNames.append(name) }
                        }
                    }
                    .fixedSize()
                    Button(action: refreshBraveWindows) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload window names from Brave")
                    Spacer()
                }
                if let braveMessage {
                    Text(braveMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Label("Brave windows", systemImage: "globe")
            } footer: {
                Text("Name a window in Brave with Window > Name Window. They come to the front on open and minimise on close.")
            }

            Section {
                LabeledContent("Today", value: formatDuration(project.timeSpent(since: Calendar.current.startOfDay(for: Date()))))
                LabeledContent("Last 7 days", value: formatDuration(project.timeSpent(since: Date().addingTimeInterval(-7 * 24 * 3600))))
                LabeledContent("Total", value: formatDuration(project.timeSpent()))
            } header: {
                Label("Time spent", systemImage: "clock")
            } footer: {
                Text("Counts while the project is open. Pauses when the Mac sleeps or you're away.")
            }

            Section {
                Button {
                    withAnimation { showAdvanced.toggle() }
                } label: {
                    HStack {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                if !showAdvanced { Text("Backup pages, window layouts and resetting the time log.") }
            }

            if showAdvanced {
                Section {
                    ForEach(project.urls, id: \.self) { url in
                        HStack {
                            Text(url).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                project.urls.removeAll { $0 == url }
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("https://...", text: $newURL)
                            .onSubmit(addURL)
                        Button("Add", action: addURL)
                            .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Label("Backup pages (optional)", systemImage: "link")
                } footer: {
                    Text("Opened in a new window if the first Brave window above has been closed.")
                }

                Section {
                    if layoutKeys.isEmpty {
                        Text("No layouts saved yet.").foregroundStyle(.secondary)
                    }
                    ForEach(layoutKeys, id: \.self) { key in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ScreenSetup.label(key) + (key == currentScreens ? " (connected now)" : ""))
                                Text("\(project.layouts[key]?.count ?? 0) windows · \(key)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                project.layouts[key] = nil
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Delete this layout")
                        }
                    }
                    HStack {
                        Button("Save Current Window Positions", action: saveLayoutNow)
                        if let layoutMessage {
                            Text(layoutMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Window layouts", systemImage: "rectangle.split.3x1")
                } footer: {
                    Text("Arrange the windows, then save. Each screen setup keeps its own layout, chosen automatically. Rename setups in Settings.")
                }
                Section {
                    Button("Reset Time Log…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        // Drop files from Finder anywhere on the project to add them.
        .dropDestination(for: URL.self) { urls, _ in
            let paths = urls.filter(\.isFileURL).map { ($0.path as NSString).abbreviatingWithTildeInPath }
            paths.forEach(add)
            return !paths.isEmpty
        }
        .confirmationDialog("Reset the time log for \(project.name)?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                project.timeLog = []
                if project.activeSession != nil {
                    project.activeSession = ActiveSession(start: Date(), lastBeat: Date())
                }
            }
        }
        .onAppear {
            // After the project shows: asking Brave takes a moment.
            DispatchQueue.main.async { refreshBraveWindows() }
            // A new project: ready to type its name.
            if project.name == Project().name { DispatchQueue.main.async { nameFocused = true } }
        }
    }

    /// e.g. "Radiation · Open now · 1h 20m today · due in 3 days"
    private var subtitle: String {
        var parts: [String] = []
        if let g = store.group(of: project) { parts.append(g.name) }
        if project.archived { parts.append("Archived") }
        if store.projects.first(where: { $0.id == project.id }).map(store.isOpen) == true {
            parts.append(store.isPaused(project) ? "Open, paused while you're away" : "Open now")
        }
        let today = project.timeSpent(since: Calendar.current.startOfDay(for: Date()))
        if today >= 60 { parts.append("\(formatDuration(today)) today") }
        if let d = project.deadline { parts.append(deadlineText(d)) }
        return parts.joined(separator: " · ")
    }

    private var currentScreens: String { ScreenSetup.currentKey() }

    private var layoutKeys: [String] {
        project.layouts.keys.sorted { a, b in
            // Current setup first
            if a == currentScreens { return true }
            if b == currentScreens { return false }
            return a < b
        }
    }

    private func saveLayoutNow() {
        let frames = Layouts.capture(project)
        if frames.isEmpty {
            layoutMessage = "No windows found. Open the project first."
        } else {
            ScreenSetup.nameCurrentIfNeeded()
            project.layouts[currentScreens] = frames
            layoutMessage = "Saved \(frames.count) window\(frames.count == 1 ? "" : "s") for \(ScreenSetup.label(currentScreens))."
        }
    }

    private var hasDeadline: Binding<Bool> {
        Binding(
            get: { project.deadline != nil },
            set: { on in
                if on {
                    if project.deadline == nil {
                        // Default: a week from now at 5pm
                        let week = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
                        project.deadline = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: week) ?? week
                    }
                } else {
                    project.deadline = nil
                }
            }
        )
    }

    private var deadlineDate: Binding<Date> {
        Binding(
            get: { project.deadline ?? Date() },
            set: { project.deadline = $0 }
        )
    }

    /// e.g. "MATLAB" for a .m file.
    private func appName(for path: String) -> String {
        guard let url = defaultApp(for: URL(fileURLWithPath: expandPath(path))) else { return "App" }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasPrefix("MATLAB") ? "MATLAB" : (name as NSString).deletingPathExtension
    }

    /// For documents: "file" (close it), "minimise" (its window) or "quit" (close it, then the app).
    private func documentCloseMode(for path: String) -> Binding<String> {
        Binding(
            get: {
                project.quitAppsOnClose.contains(path) ? "quit"
                    : project.minimiseAppsOnClose.contains(path) ? "minimise" : "file"
            },
            set: { mode in
                project.quitAppsOnClose.removeAll { $0 == path }
                project.minimiseAppsOnClose.removeAll { $0 == path }
                if mode == "quit" { project.quitAppsOnClose.append(path) }
                if mode == "minimise" { project.minimiseAppsOnClose.append(path) }
            }
        )
    }

    private func appCloseMode(for path: String) -> Binding<String> {
        Binding(
            get: {
                project.minimiseAppsOnClose.contains(path) ? "minimise"
                    : project.hideAppsOnClose.contains(path) ? "hide" : "quit"
            },
            set: { mode in
                project.hideAppsOnClose.removeAll { $0 == path }
                project.minimiseAppsOnClose.removeAll { $0 == path }
                if mode == "hide" { project.hideAppsOnClose.append(path) }
                if mode == "minimise" { project.minimiseAppsOnClose.append(path) }
            }
        )
    }

    private func refreshBraveWindows() {
        let result = Brave.windowNames()
        braveNames = result.names
        braveMessage = result.error
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }.forEach(add)
    }

    /// Adds a file. Apps (and MATLAB files) minimise their window on close unless changed.
    private func add(_ path: String) {
        guard !project.files.contains(path) else { return }
        project.files.append(path)
        if isApp(path) || closesWholeApp(path) { project.minimiseAppsOnClose.append(path) }
    }

    /// A file that's been moved or renamed: look for one with the same name (Spotlight),
    /// otherwise let the user pick it. Its settings and saved positions move with it.
    private func relink(_ old: String) {
        let name = (old as NSString).lastPathComponent
        var found: String?
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["-onlyin", NSHomeDirectory(), "-name", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        if (try? task.run()) != nil {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            task.waitUntilExit()
            let matches = out.split(separator: "\n").map(String.init)
                .filter { ($0 as NSString).lastPathComponent == name && !$0.contains("/.Trash/") }
            if matches.count == 1,
               Alerts.confirm("Found \(name)", "Use this file?\n\n\((matches[0] as NSString).abbreviatingWithTildeInPath)", ok: "Use It") {
                found = matches[0]
            }
        }
        if found == nil {
            let panel = NSOpenPanel()
            panel.message = "Where is \(name) now?"
            panel.prompt = "Use"
            var dir = URL(fileURLWithPath: expandPath(old)).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: dir.path) && dir.path != "/" { dir.deleteLastPathComponent() }
            panel.directoryURL = dir
            guard panel.runModal() == .OK, let url = panel.url else { return }
            found = url.path
        }
        guard let newPath = found.map({ ($0 as NSString).abbreviatingWithTildeInPath }), newPath != old else { return }
        func swap(_ list: inout [String]) { list = list.map { $0 == old ? newPath : $0 } }
        swap(&project.files)
        swap(&project.hideAppsOnClose)
        swap(&project.minimiseAppsOnClose)
        swap(&project.quitAppsOnClose)
        for key in project.layouts.keys {
            project.layouts[key] = project.layouts[key]?.map { f in
                var f = f
                if f.kind == "file" && f.key == old { f.key = newPath }
                return f
            }
        }
    }

    private func addURL() {
        var url = newURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        if !url.contains("://") { url = "https://" + url }
        if !project.urls.contains(url) { project.urls.append(url) }
        newURL = ""
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
