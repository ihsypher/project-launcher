import SwiftUI
import AppKit

struct EditorView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        NavigationSplitView {
            List(selection: $store.editorSelection) {
                ForEach(store.flattened(), id: \.project.id) { item in
                    Text(item.project.name)
                        .padding(.leading, CGFloat(item.depth) * 14)
                        .tag(item.project.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        store.editorSelection = store.addProject()
                    } label: { Image(systemName: "plus") }
                    .help("Add project")

                    Button {
                        store.editorSelection = store.addProject(parent: store.editorSelection)
                    } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(store.editorSelection == nil)
                    .help("Add a sub-project under the selected project")

                    Button {
                        if let id = store.editorSelection {
                            store.delete(id: id)
                            store.editorSelection = nil
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(store.editorSelection == nil)
                    .help("Delete selected project (its sub-projects move up a level)")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = store.editorSelection, store.projects.contains(where: { $0.id == id }) {
                ProjectDetail(project: binding(for: id))
                    .id(id)
            } else {
                Text("Select a project, or press + to add one")
                    .foregroundStyle(.secondary)
            }
        }
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

struct ProjectDetail: View {
    @EnvironmentObject var store: ProjectStore
    @Binding var project: Project
    @State private var newURL = ""
    @State private var braveNames: [String] = []
    @State private var braveMessage: String?
    @State private var layoutMessage: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $project.name)
                Picker("Part of", selection: $project.parentID) {
                    Text("Nothing (top level)").tag(UUID?.none)
                    ForEach(parentOptions) { p in
                        Text(store.path(of: p)).tag(UUID?.some(p.id))
                    }
                }
                Toggle("Deadline", isOn: hasDeadline)
                if project.deadline != nil {
                    DatePicker("Due", selection: deadlineDate, displayedComponents: [.date, .hourAndMinute])
                    Text(deadlineText(project.deadline ?? Date()).capitalizedFirst)
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                        if isApp(path) {
                            Picker("On close", selection: appCloseMode(for: path)) {
                                Text("Quit").tag("quit")
                                Text("Hide").tag("hide")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .help("What happens to this app when you close the project")
                        }
                        Button {
                            project.files.removeAll { $0 == path }
                            project.hideAppsOnClose.removeAll { $0 == path }
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                    .help(path)
                }
                Button("Add Files...", action: addFiles)
            } header: {
                Text("Files")
            } footer: {
                Text("Files open in their default app (PDF in Preview, .docx in Word, .xlsx in Excel), and closing the project closes only those windows. You can add apps too (e.g. Claude from Applications): closing the project quits them, or hides them if you choose Hide.")
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
                Text("Claude chat or project (optional)")
            } footer: {
                Text("Open the chat or project at claude.ai in Brave, copy the address (it ends in a long ID) and paste it here. Opening the project jumps straight to it in the Claude app. Share links (claude.ai/share/...) won't work.")
            }

            Section {
                HStack {
                    Picker("Window", selection: $project.braveWindowName) {
                        Text("None").tag("")
                        ForEach(windowOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    Button(action: refreshBraveWindows) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reload window names from Brave")
                }
                if let braveMessage {
                    Text(braveMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Brave window")
            } footer: {
                Text("Pick one of your named Brave windows. Opening the project brings it to the front; closing the project minimises it.")
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
                Text("Backup pages (optional)")
            } footer: {
                Text("Only used if the window above isn't open, e.g. after you've closed it. These pages open in a new Brave window with that name. You can leave this empty.")
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
                Text("Window layouts")
            } footer: {
                Text("Open the project, arrange its windows how you like (e.g. Claude on the left, Word on the right), then save. Each screen setup keeps its own layout, so laptop-only and external-monitor arrangements are stored separately and picked automatically.")
            }

            Section {
                LabeledContent("Today", value: formatDuration(project.timeSpent(since: Calendar.current.startOfDay(for: Date()))))
                LabeledContent("Last 7 days", value: formatDuration(project.timeSpent(since: Date().addingTimeInterval(-7 * 24 * 3600))))
                LabeledContent("Total", value: formatDuration(project.timeSpent()))
                if !subProjects.isEmpty {
                    LabeledContent("Total with sub-projects",
                                   value: formatDuration(([project] + subProjects).reduce(0) { $0 + $1.timeSpent() }))
                }
                Button("Reset Time Log...", role: .destructive) { confirmReset = true }
            } header: {
                Text("Time spent")
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
        .onAppear(perform: refreshBraveWindows)
    }

    /// Names currently in Brave, plus the saved one (so it still shows if that window is closed right now).
    private var windowOptions: [String] {
        var names = braveNames
        let saved = project.braveWindowName
        if !saved.isEmpty && !names.contains(saved) { names.insert(saved, at: 0) }
        return names
    }

    private var subProjects: [Project] { store.descendants(of: project.id) }

    /// Anything except this project and those under it (which would make a loop).
    private var parentOptions: [Project] {
        let excluded = Set([project.id] + subProjects.map(\.id))
        return store.flattened().map(\.project).filter { !excluded.contains($0.id) }
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
