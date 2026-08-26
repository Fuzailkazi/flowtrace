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
    @State private var notes: [String: ProjectNote] = [:]
    @State private var editing: String?
    @State private var draft = ""
    @State private var loading = true
    @FocusState private var focused: Bool

    private let tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if loading && state.agents.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, Journal.Space.xl)
                } else {
                    agents
                    servers
                    if state.agents.isEmpty && state.servers.isEmpty { empty }
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
            HStack(alignment: .firstTextBaseline) {
                Text("Right now")
                    .font(.journalTitle(25))
                    .foregroundStyle(Journal.ink)
                Spacer()
                Text(state.capturedAt, format: .dateTime.hour().minute())
                    .font(.observed(12)).monospacedDigit()
                    .foregroundStyle(Journal.inkSoft)
            }

            if let headline = state.headline {
                // The idle count is the surprising half, so it gets the colour.
                HStack(spacing: 5) {
                    Text(headline)
                        .font(.observed(12))
                        .foregroundStyle(state.idleAgents.isEmpty ? Journal.inkSoft : Journal.amber)
                }
            }
        }
        .padding(.top, Journal.Space.l)
        .padding(.bottom, Journal.Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Journal.ruleFirm) }
    }

    // MARK: - Agents

    @ViewBuilder
    private var agents: some View {
        ForEach(state.agents) { agent in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Journal.Space.s) {
                    Circle()
                        .fill(colour(for: agent.state))
                        .frame(width: 7, height: 7)

                    Text(agent.repositoryName)
                        .font(.observed(14, weight: .semibold))
                        .foregroundStyle(Journal.ink)

                    Text(agent.agent.label)
                        .font(.observed(10.5, weight: .medium))
                        .foregroundStyle(Journal.pen)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))

                    Spacer(minLength: Journal.Space.s)

                    Text(agent.lastActivityLabel)
                        .font(.observed(11))
                        .foregroundStyle(agent.state == .idle ? Journal.amber : Journal.inkSoft)
                }

                if let prompt = agent.lastPrompt {
                    Text(prompt)
                        .font(.observed(12.5))
                        .foregroundStyle(Journal.inkMid)
                        .lineLimit(2)
                }

                projectNote(for: agent.workingDirectory, name: agent.repositoryName)
            }
            .padding(.vertical, Journal.Space.m)
            .overlay(alignment: .bottom) { Divider().overlay(Journal.rule) }
            .contextMenu {
                Button("Open in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: agent.workingDirectory))
                }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(agent.workingDirectory, forType: .string)
                }
            }
        }
    }

    /// What you're building here — written once, kept forever, shown every time.
    @ViewBuilder
    private func projectNote(for path: String, name: String) -> some View {
        let note = notes[FilePathCanon.canonical(path)]

        if editing == FilePathCanon.canonical(path) {
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

    // MARK: - Servers

    @ViewBuilder
    private var servers: some View {
        if !state.servers.isEmpty {
            Text("Listening")
                .font(.observed(10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Journal.inkSoft)
                .padding(.top, Journal.Space.l)
                .padding(.bottom, Journal.Space.s)

            ForEach(state.servers) { server in
                HStack(spacing: Journal.Space.m) {
                    Text(":\(String(server.port))")
                        .font(.observed(13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Journal.pen)
                        .frame(width: 58, alignment: .leading)

                    Text(server.projectName ?? server.processName)
                        .font(.observed(13))
                        .foregroundStyle(Journal.ink)

                    Text(server.processName)
                        .font(.observed(11))
                        .foregroundStyle(Journal.inkSoft)

                    Spacer()

                    Button("Open") {
                        if let url = URL(string: server.address) { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.plain)
                    .font(.observed(11, weight: .medium))
                    .foregroundStyle(Journal.pen)
                }
                .padding(.vertical, Journal.Space.s)
                .overlay(alignment: .bottom) { Divider().overlay(Journal.rule) }
            }
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

    private func colour(for agentState: LiveAgent.State) -> Color {
        switch agentState {
        case .working: .green
        case .waiting: Journal.pen
        case .idle: Journal.ruleFirm
        }
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
        }
        editing = nil
    }

    /// Reading processes shells out, so it never happens on the main actor.
    private func refresh() async {
        let store = model.store
        let read = await Task.detached(priority: .userInitiated) {
            (LiveStateReader().read(), (try? store.allProjectNotes()) ?? [])
        }.value

        state = read.0
        notes = Dictionary(uniqueKeysWithValues: read.1.map { ($0.repositoryPath, $0) })
        loading = false
    }
}
