import SwiftUI
import UniformTypeIdentifiers
import FlowTraceCore

/// The one place context enters FlowTrace by hand.
///
/// Every tab is listed with its full URL and a checkbox before anything is
/// stored — capture is explicit, and the user can see exactly what it will keep.
struct CaptureSheet: View {
    @Bindable var model: AppModel
    var presetThreadId: String?
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case tabs = "Browser tabs"
        case repository = "Repository"
        case session = "Agent session"
    }

    @State private var mode: Mode = .tabs
    @State private var threadId: String?
    @State private var newThreadTitle = ""

    // Tabs
    @State private var browser: SupportedBrowser?
    @State private var availableBrowsers: [SupportedBrowser] = []
    @State private var tabs: [CapturedTab] = []
    @State private var selected: Set<CapturedTab.ID> = []
    @State private var tabNote = ""
    @State private var readError: String?
    @State private var recovery: String?
    @State private var isReading = false

    // Repository / session
    @State private var repositoryPath = ""
    @State private var gitState: GitState?
    @State private var contextNote = ""
    @State private var contextNextStep = ""
    @State private var agent: AgentName?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear {
            threadId = presetThreadId ?? model.continueWhereYouLeftOff.first?.id
            availableBrowsers = BrowserTabReader().availableBrowsers()
            browser = availableBrowsers.first
            if mode == .tabs { readTabs(activeOnly: false) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Capture context").font(.system(size: 15, weight: .semibold))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, newValue in
                if newValue == .tabs, tabs.isEmpty { readTabs(activeOnly: false) }
            }
        }
        .padding(Theme.Space.l)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                switch mode {
                case .tabs: tabsSection
                case .repository: repositorySection
                case .session: sessionSection
                }
            }
            .padding(Theme.Space.l)
        }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabsSection: some View {
        if availableBrowsers.isEmpty {
            EmptyState(
                icon: "safari",
                title: "No supported browser is running",
                message: "Open Chrome, Brave, Safari, Arc, Dia, Edge, Opera or Vivaldi and try again. "
                    + "FlowTrace won't launch a browser just to read its tabs."
            )
        } else {
            HStack(spacing: Theme.Space.s) {
                Picker("", selection: Binding(
                    get: { browser ?? availableBrowsers[0] },
                    set: { browser = $0; readTabs(activeOnly: false) }
                )) {
                    ForEach(availableBrowsers) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)

                Button("Front window") { readTabs(activeOnly: false) }
                Button("Current tab only") { readTabs(activeOnly: true) }
                Spacer()
                if isReading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            if let readError {
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(readError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        if let recovery {
                            Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !tabs.isEmpty {
                HStack {
                    Text("FlowTrace stores the title and URL only — never page contents or cookies.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(selected.count == tabs.count ? "Deselect all" : "Select all") {
                        selected = selected.count == tabs.count ? [] : Set(tabs.map(\.id))
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(tabs) { tab in
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                Toggle("", isOn: Binding(
                                    get: { selected.contains(tab.id) },
                                    set: { on in
                                        if on { selected.insert(tab.id) } else { selected.remove(tab.id) }
                                    }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: Theme.Space.xs) {
                                        Text(tab.pageTitle).font(.system(size: 12)).lineLimit(1)
                                        if tab.isActive { Chip(text: "current", color: .blue) }
                                    }
                                    Text(tab.url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                LabeledField("Why did you open these?", text: $tabNote, axis: .vertical)
            }
        }
    }

    // MARK: - Repository

    private var repositorySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Button("Choose folder…") { pickFolder() }
                if !repositoryPath.isEmpty {
                    Text(repositoryPath).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
            }
            .controlSize(.small)

            if let gitState {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(gitState.repositoryName).font(.system(size: 13, weight: .medium))
                            Chip(text: gitState.branch, color: .blue)
                            if gitState.dirtyFileCount > 0 {
                                Chip(text: "\(gitState.dirtyFileCount) uncommitted", color: .orange)
                            }
                            if gitState.commitsAhead > 0 {
                                Chip(text: "\(gitState.commitsAhead) unpushed", color: .orange)
                            }
                        }
                        if let sha = gitState.headSha {
                            Text("HEAD \(sha.prefix(7)) · \(gitState.daysSinceLastCommit)d since last commit")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
            } else if !repositoryPath.isEmpty {
                Card {
                    Label("That folder isn't inside a git repository.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }

            agentPicker
            LabeledField("Note", text: $contextNote, axis: .vertical)
            LabeledField("What should you do next here?", text: $contextNextStep, axis: .vertical)
        }
    }

    // MARK: - Manual agent session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("For agents FlowTrace can't read automatically — Cursor, OpenCode, Gemini CLI "
                 + "and anything else. Claude Code and Codex sessions are found by scanning.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Button("Choose the repository…") { pickFolder() }
                if let gitState {
                    Text("\(gitState.repositoryName) · \(gitState.branch)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .controlSize(.small)

            agentPicker
            LabeledField("What did you ask it to do?", text: $contextNote, axis: .vertical)
            LabeledField("What's left?", text: $contextNextStep, axis: .vertical)
        }
    }

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            FieldLabel(text: "Agent")
            Picker("", selection: $agent) {
                Text("None").tag(AgentName?.none)
                ForEach(AgentName.allCases, id: \.self) { Text($0.label).tag(AgentName?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 200)
            .controlSize(.small)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(text: "Attach to")
                Picker("", selection: $threadId) {
                    Text("New thread…").tag(String?.none)
                    ForEach(model.threads.filter { $0.status != .completed }) {
                        Text($0.title).tag(String?.some($0.id))
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            if threadId == nil {
                VStack(alignment: .leading, spacing: 3) {
                    FieldLabel(text: "New thread title")
                    TextField("Title", text: $newThreadTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }

            Spacer()
            Button("Cancel") { dismiss() }
            Button("Capture") { capture() }
                .buttonStyle(.borderedProminent)
                .disabled(!canCapture)
        }
        .controlSize(.small)
        .padding(Theme.Space.l)
    }

    private var canCapture: Bool {
        let hasTarget = threadId != nil || !newThreadTitle.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasTarget else { return false }
        switch mode {
        case .tabs: return !selected.isEmpty
        case .repository, .session: return gitState != nil
        }
    }

    // MARK: - Actions

    private func readTabs(activeOnly: Bool) {
        guard let browser else { return }
        isReading = true
        readError = nil
        recovery = nil
        let reader = BrowserTabReader()

        Task.detached(priority: .userInitiated) {
            do {
                let result = activeOnly
                    ? [try reader.activeTab(of: browser)].compactMap { $0 }
                    : try reader.tabsInFrontWindow(of: browser)
                await MainActor.run {
                    tabs = result
                    // Preselect everything: the user opened these on purpose.
                    selected = Set(result.map(\.id))
                    isReading = false
                }
            } catch {
                await MainActor.run {
                    tabs = []
                    selected = []
                    readError = error.localizedDescription
                    recovery = (error as? BrowserReadError)?.recoverySuggestion
                    isReading = false
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.path
        gitState = GitProbe().probe(url.path)
    }

    private func capture() {
        guard let target = resolveThread() else { return }
        do {
            switch mode {
            case .tabs:
                let chosen = tabs.filter { selected.contains($0.id) }
                _ = try model.store.attach(
                    tabs: chosen.map { $0.asContext(note: tabNote) }, to: target
                )
                model.toast = Toast(message: "Captured \(chosen.count) tab\(chosen.count == 1 ? "" : "s")")
            case .repository, .session:
                guard let state = gitState else { return }
                _ = try model.store.attach(code: CodeContext(
                    agentName: agent,
                    repositoryName: state.repositoryName,
                    repositoryPath: state.topLevel,
                    branch: state.branch,
                    latestCommit: state.headSha,
                    note: contextNote,
                    nextStep: contextNextStep,
                    dirtyFileCount: state.dirtyFileCount,
                    lastCommitAt: state.headDate,
                    commitsAhead: state.commitsAhead,
                    commitsBehind: state.commitsBehind
                ), to: target)
                model.toast = Toast(message: "Attached \(state.repositoryName)")
            }
            model.refresh()
            dismiss()
        } catch {
            model.toast = Toast(
                message: "Couldn't capture that: \(error.localizedDescription)", isError: true
            )
        }
    }

    private func resolveThread() -> String? {
        if let threadId { return threadId }
        let title = newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let thread = try? model.store.create(WorkThread(title: title))
        model.refresh()
        return thread?.id
    }
}

/// Creating a thread by hand — title, why, and what's next.
struct NewThreadSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var intent = ""
    @State private var nextStep = ""
    @State private var priority: Priority = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("New work thread").font(.system(size: 15, weight: .semibold))

            LabeledField("Title", text: $title)
            LabeledField("Why am I doing this?", text: $intent, axis: .vertical)
            LabeledField("What should I do next?", text: $nextStep, axis: .vertical)

            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(text: "Priority")
                Picker("", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.create(title: title, intent: intent, nextStep: nextStep, priority: priority)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480, height: 420)
    }
}
