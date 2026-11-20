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
                ForEach(store.projects(in: nil)) { p in
                    projectRow(p)
                }
                .onMove { store.moveProjects(in: nil, from: $0, to: $1) }

                ForEach(store.groups) { g in
                    groupRow(g)
                    ForEach(store.projects(in: g.id)) { p in
                        projectRow(p)
                    }
                    .onMove { store.moveProjects(in: g.id, from: $0, to: $1) }
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
            SettingsView()
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
        .padding(.leading, p.groupID == nil ? 0 : 14)
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
                Button("New Group...") {
                    let g = store.addGroup()
                    store.moveProject(p.id, toGroup: g)
                    store.editorSelection = g
                }
            }
            Divider()
            Button("Delete Project...", role: .destructive) { pendingDelete = p.id }
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
            Button("Delete Group...", role: .destructive) { pendingDelete = g.id }
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
        var subset = projects(in: groupID)
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
        projects(in: nil).map(\.id) + groups.flatMap { [$0.id] + projects(in: $0.id).map(\.id) }
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
                        TextField("Group name", text: $group.name)
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
                        Spacer()
                        Text(formatDuration(p.timeSpent())).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.editorSelection = p.id }
                }
            } header: {
                Label("Projects", systemImage: "square.stack")
            } footer: {
                Text("Add a project with + while this group is selected, or right-click a project and choose Move to Group. Drag projects to reorder them.")
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

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
                    Text("The log records what opening and closing projects did (which windows were found, closed or skipped). Send the file if something goes wrong.")
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
        .frame(width: 440, height: 300)
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
                        TextField("Project name", text: $project.name)
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                            .focused($nameFocused)
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
                        }
                        Spacer()
                        if isApp(path) || closesWholeApp(path) {
                            Picker("On close", selection: appCloseMode(for: path)) {
                                Text(closesWholeApp(path) ? "Quit \(appName(for: path))" : "Quit").tag("quit")
                                Text(closesWholeApp(path) ? "Hide \(appName(for: path))" : "Hide").tag("hide")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help(closesWholeApp(path)
                                  ? "\(appName(for: path)) can't close one file, so closing the project quits or hides it (unless another open project uses it)"
                                  : "What happens to this app when you close the project")
                        } else if isOfficeDocument(path) {
                            Picker("On close", selection: officeCloseMode(for: path)) {
                                Text("Close File").tag("file")
                                Text("Quit \(appName(for: path).replacingOccurrences(of: "Microsoft ", with: ""))").tag("quit")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help("Close just this file, or quit the whole app too (unless another open project uses it). Quitting asks about any other unsaved documents.")
                        }
                        Button {
                            project.files.removeAll { $0 == path }
                            project.hideAppsOnClose.removeAll { $0 == path }
                            project.quitAppsOnClose.removeAll { $0 == path }
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                    .help(path)
                }
                HStack {
                    Button("Add Files...", action: addFiles)
                    Button("Add Open Windows...") { store.updateFromOpenWindows(project.id) }
                        .help("Add documents that are open right now, and save the window layout")
                }
            } header: {
                Label("Files", systemImage: "doc.on.doc")
            } footer: {
                Text("Files open in their default app (PDF in Preview, .docx in Word, .xlsx in Excel), and closing the project closes only those windows. You can add apps too (e.g. Claude from Applications): closing the project quits them, or hides them if you choose Hide. MATLAB can't close a single file, so a project with MATLAB files quits or hides MATLAB instead. Apps another open project still uses are left running.")
            }

            Section {
                TextField("https://claude.ai/chat/...", text: $project.claudeLink)
                if !project.claudeLink.trimmingCharacters(in: .whitespaces).isEmpty
                    && ClaudeApp.deepLink(from: project.claudeLink) == nil {
                    Text("Paste a claude.ai chat or project link.")
                        .font(.caption).foregroundStyle(.red)
                }
                Picker("When the project closes", selection: $project.claudeOnClose) {
                    Text("Hide Claude").tag("hide")
                    Text("Quit Claude").tag("quit")
                    Text("Leave it").tag("leave")
                }
            } header: {
                Label("Claude chat or project (optional)", systemImage: "bubble.left.and.bubble.right")
            } footer: {
                Text("Open the chat or project at claude.ai in Brave, copy the address (it ends in a long ID) and paste it here. Opening the project jumps straight to it in the Claude app. Share links (claude.ai/share/...) won't work.")
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
                Text("Add any of your named Brave windows (Window > Name Window... in Brave). Opening the project brings them to the front; closing the project minimises them.")
            }

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
                Text("Only used if the first Brave window above isn't open, e.g. after you've closed it. These pages open in a new Brave window with that name. You can leave this empty.")
            }

            Section {
                if layoutKeys.isEmpty {
                    Text("No layouts saved yet.").foregroundStyle(.secondary)
                }
                ForEach(layoutKeys, id: \.self) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key == currentScreens ? "This screen setup" : "Other screen setup")
                            Text("\(key), \(project.layouts[key]?.count ?? 0) windows")
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
                Text("Open the project, arrange its windows how you like (e.g. Claude on the left, Word on the right), then save. Each screen setup keeps its own layout, so laptop-only and external-monitor arrangements are stored separately and picked automatically.")
            }

            Section {
                LabeledContent("Today", value: formatDuration(project.timeSpent(since: Calendar.current.startOfDay(for: Date()))))
                LabeledContent("Last 7 days", value: formatDuration(project.timeSpent(since: Date().addingTimeInterval(-7 * 24 * 3600))))
                LabeledContent("Total", value: formatDuration(project.timeSpent()))
                Button("Reset Time Log...", role: .destructive) { confirmReset = true }
            } header: {
                Label("Time spent", systemImage: "clock")
            } footer: {
                Text("Counts the time the project is open (ticked in the menu), pausing while the Mac is asleep.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset the time log for \(project.name)?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                project.timeLog = []
                if project.activeSession != nil {
                    project.activeSession = ActiveSession(start: Date(), lastBeat: Date())
                }
            }
        }
        .onAppear {
            refreshBraveWindows()
            // A new project: ready to type its name.
            if project.name == Project().name { DispatchQueue.main.async { nameFocused = true } }
        }
    }

    /// e.g. "Radiation · Open · 1h 20m today · 3 days left"
    private var subtitle: String {
        var parts: [String] = []
        if let g = store.group(of: project) { parts.append(g.name) }
        let open = store.projects.first(where: { $0.id == project.id }).map(store.isOpen) ?? false
        parts.append(open ? "Open" : "Closed")
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
            project.layouts[currentScreens] = frames
            layoutMessage = "Saved \(frames.count) window\(frames.count == 1 ? "" : "s")."
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
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: expandPath(path))) else { return "App" }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasPrefix("MATLAB") ? "MATLAB" : (name as NSString).deletingPathExtension
    }

    private func officeCloseMode(for path: String) -> Binding<String> {
        Binding(
            get: { project.quitAppsOnClose.contains(path) ? "quit" : "file" },
            set: { mode in
                project.quitAppsOnClose.removeAll { $0 == path }
                if mode == "quit" { project.quitAppsOnClose.append(path) }
            }
        )
    }

    private func appCloseMode(for path: String) -> Binding<String> {
        Binding(
            get: { project.hideAppsOnClose.contains(path) ? "hide" : "quit" },
            set: { mode in
                project.hideAppsOnClose.removeAll { $0 == path }
                if mode == "hide" { project.hideAppsOnClose.append(path) }
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
        for url in panel.urls {
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            if !project.files.contains(path) { project.files.append(path) }
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
