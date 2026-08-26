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
    @State var browser: SupportedBrowser?
    @State var availableBrowsers: [SupportedBrowser] = []
    @State var tabs: [CapturedTab] = []
    @State var selected: Set<CapturedTab.ID> = []
    @State var tabNote = ""
    @State var readError: String?
    @State var recovery: String?
    @State var isReading = false

    // Repository / session
    @State var repositoryPath = ""
    @State var gitState: GitState?
    @State var contextNote = ""
    @State var contextNextStep = ""
    @State var agent: AgentName?

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

    func readTabs(activeOnly: Bool) {
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

    func pickFolder() {
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

