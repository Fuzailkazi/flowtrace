import SwiftUI
import FlowTraceCore

/// The state of your machine, right now.
///
/// The front door, because "eleven agents running, eight idle for four days" is
/// a stronger thing to open on than a record of what you did at 09:12. History
/// is one click away; this is what you can act on.
struct NowView: View {
    @Bindable var model: AppModel

    @State private var state = LiveState()
    @State private var projects: [LiveProject] = []
    @State private var notes: [String: ProjectNote] = [:]
    @State private var editing: String?
    @State private var draft = ""
    @State private var loading = true
    @State private var hovering: String?
    @State private var ignored: Set<String> = []
    @FocusState private var focused: Bool

    private let tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var forgotten: Int { projects.filter(\.isForgotten).count }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if loading && state.agents.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, Journal.Space.xl)
                } else if projects.isEmpty {
                    empty
                } else {
                    ForEach(projects) { project in
                        projectBlock(project)
                    }
                }
            }
            .padding(.horizontal, Journal.Space.xl)
            .padding(.bottom, Journal.Space.xl)
        }
        .background(Journal.paper)
        .task { await refresh() }
        .onReceive(tick) { _ in Task { await refresh() } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            HStack(alignment: .center, spacing: Journal.Space.m) {
                Text("Right now")
                    .font(.journalTitle(25))
                    .foregroundStyle(Journal.ink)
                SurfaceSwitch(model: model)
                Spacer()
                Text(state.capturedAt, format: .dateTime.hour().minute())
                    .font(.observed(12)).monospacedDigit()
                    .foregroundStyle(Journal.inkSoft)
            }

            // The forgotten count is the surprising half, so it gets the colour.
            HStack(spacing: 4) {
                Text("\(projects.count) place\(projects.count == 1 ? "" : "s")")
                    .foregroundStyle(Journal.inkSoft)
                if forgotten > 0 {
                    Text("·").foregroundStyle(Journal.ruleFirm)
                    Text("\(forgotten) left running and forgotten")
                        .foregroundStyle(Journal.amber)
                }
            }
            .font(.observed(12))
        }
        .padding(.top, Journal.Space.l)
        .padding(.bottom, Journal.Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Journal.ruleFirm) }
    }

    // MARK: - One place

    /// Everything happening in one project: its agents, its servers, and what
    /// you said you were building. Grouped because work happens in places — the
    /// previous split across two lists hid that a project could have an agent
    /// idle for days *and* a server still holding a port.
    private func projectBlock(_ project: LiveProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Journal.Space.s) {
                Circle()
                    .fill(colour(for: project))
                    .frame(width: 7, height: 7)

                Text(project.name)
                    .font(.observed(14.5, weight: .semibold))
                    .foregroundStyle(Journal.ink)

                ForEach(Array(Set(project.agents.map(\.agent))), id: \.self) { agent in
                    Text(agent.label)
                        .font(.observed(10.5, weight: .medium))
                        .foregroundStyle(Journal.pen)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))
                }

                Spacer(minLength: Journal.Space.s)

                if hovering == project.path {
                    Menu {
                        if project.note != nil {
                            Button("Clear what I wrote") { clearNote(project) }
                        }
                        Button("Hide this project") { hide(project) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Journal.inkSoft)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Hide this project, or clear its note")
                }

                Text(project.statusLabel)
                    .font(.observed(11))
                    .foregroundStyle(project.isForgotten ? Journal.amber : Journal.inkSoft)
            }

            if let prompt = project.lastPrompt {
                Text(prompt)
                    .font(.observed(12.5))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(2)
            }

            if !project.servers.isEmpty {
                HStack(spacing: Journal.Space.s) {
                    Text("listening")
                        .font(.observed(10.5))
                        .foregroundStyle(Journal.inkSoft)
                    ForEach(project.servers) { server in
                        Button {
                            if let url = URL(string: server.address) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text(":\(String(server.port))")
                                .font(.observed(11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Journal.pen)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(server.address)")
                    }
                    Spacer()
                }
            }

            projectNote(for: project.path, name: project.name)
        }
        .padding(.vertical, Journal.Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Journal.rule) }
        .onHover { hovering = $0 ? project.path : (hovering == project.path ? nil : hovering) }
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.path, forType: .string)
            }
            Divider()
            if project.note != nil {
                Button("Clear what I wrote") { clearNote(project) }
            }
            Button("Hide this project", role: .destructive) { hide(project) }
        }
    }

    /// What you're building here — written once, kept forever, shown every time.
    ///
    /// Keyed on the repository rather than the session or the process, so it
    /// outlives the thing it describes.
    @ViewBuilder
    private func projectNote(for path: String, name: String) -> some View {
        let canonical = FilePathCanon.canonical(path)
        let note = notes[canonical]

        if editing == canonical {
            HStack(spacing: Journal.Space.s) {
                TextField("what are you building here?", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.yourWords(15))
                    .foregroundStyle(Journal.ink)
                    .focused($focused)
                    .onSubmit { save(path: path, name: name) }
                Button("Save") { save(path: path, name: name) }
                    .buttonStyle(.plain)
                    .font(.observed(11, weight: .medium))
                    .foregroundStyle(Journal.pen)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Journal.pen, lineWidth: 1))
            .onExitCommand { editing = nil }

        } else if let note, !note.building.isEmpty {
            Text("“\(note.building)”")
                .font(.yourWords(15))
                .foregroundStyle(Journal.ink)
                .onTapGesture { begin(path: path, existing: note.building) }

        } else {
            Button {
                begin(path: path, existing: "")
            } label: {
                HStack(spacing: Journal.Space.s) {
                    Circle().fill(Journal.amber).frame(width: 6, height: 6)
                    Text("what are you building here?")
                        .font(.yourWords(14.5))
                        .foregroundStyle(Journal.amber)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            Text("Nothing running.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)
            Text("No coding agents and no local servers. Start one and it appears here.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
        }
        .padding(.top, Journal.Space.xl)
    }

    // MARK: - Data

    private func colour(for project: LiveProject) -> Color {
        if project.agents.contains(where: { $0.state == .working }) { return .green }
        if project.agents.contains(where: { $0.state == .waiting }) { return Journal.pen }
        return Journal.ruleFirm
    }

    /// Hiding rather than deleting, because the process is still running and
    /// would simply reappear. Reuses the same ignore list the detector uses, so
    /// there is one place to undo it: Settings → Sources.
    private func hide(_ project: LiveProject) {
        do {
            try model.store.ignore(path: project.path, reason: "hidden from Now")
            ignored.insert(FilePathCanon.canonical(project.path))
            projects = state.projects(notes: notes).filter { !ignored.contains($0.path) }
            model.toast = Toast(message: "Hiding \(project.name) — undo in Settings")
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    private func clearNote(_ project: LiveProject) {
        try? model.store.deleteProjectNote(repositoryPath: project.path)
        notes.removeValue(forKey: FilePathCanon.canonical(project.path))
        projects = state.projects(notes: notes).filter { !ignored.contains($0.path) }
    }

    private func begin(path: String, existing: String) {
        editing = FilePathCanon.canonical(path)
        draft = existing
        focused = true
    }

    private func save(path: String, name: String) {
        let canonical = FilePathCanon.canonical(path)
        var note = notes[canonical] ?? ProjectNote(repositoryPath: path, repositoryName: name)
        note.building = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved = try? model.store.saveProjectNote(note) {
            notes[canonical] = saved
            projects = state.projects(notes: notes).filter { !ignored.contains($0.path) }
        }
        editing = nil
    }

    /// Reading processes shells out, so it never happens on the main actor.
    private func refresh() async {
        let store = model.store
        let read = await Task.detached(priority: .userInitiated) {
            (
                LiveStateReader().read(),
                (try? store.allProjectNotes()) ?? [],
                (try? store.ignoredPaths()) ?? []
            )
        }.value

        state = read.0
        notes = Dictionary(uniqueKeysWithValues: read.1.map { ($0.repositoryPath, $0) })
        ignored = read.2
        projects = read.0.projects(notes: notes).filter { !ignored.contains($0.path) }
        loading = false
    }
}
