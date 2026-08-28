import Foundation
import SwiftUI
import FlowTraceCore

/// What the main content area is showing.
enum Route: Hashable {
    /// What is running right now — the app's front door.
    case now
    /// The day you can read.
    case timeline
    case dashboard
    case status(ThreadStatus)
    case thread(String)
    case recentCaptures
    case settings
}

enum ScanState: Equatable {
    case idle
    case running(phase: String, fraction: Double)
    case finished(ScanSummary)
    case failed(String)

    struct ScanSummary: Equatable {
        var proposals: Int
        var sessions: Int
        var repositories: Int
        var duration: TimeInterval
    }

    var isRunning: Bool { if case .running = self { true } else { false } }
}

/// A short confirmation of something that just happened.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var isError = false
}

/// Which local sources the user has agreed FlowTrace may read.
///
/// Nothing is scanned until these are switched on, and switching one off takes
/// effect on the next scan without touching what was already captured.
struct ConsentSettings: Equatable {
    var claudeCode = false
    var codex = false
    var hasCompletedOnboarding = false

    var anyEnabled: Bool { claudeCode || codex }

    static let defaultsKey = "flowtrace.consent"

    static func load() -> ConsentSettings {
        let defaults = UserDefaults.standard
        guard let raw = defaults.dictionary(forKey: defaultsKey) else { return ConsentSettings() }
        return ConsentSettings(
            claudeCode: raw["claudeCode"] as? Bool ?? false,
            codex: raw["codex"] as? Bool ?? false,
            hasCompletedOnboarding: raw["hasCompletedOnboarding"] as? Bool ?? false
        )
    }

    func save() {
        UserDefaults.standard.set([
            "claudeCode": claudeCode,
            "codex": codex,
            "hasCompletedOnboarding": hasCompletedOnboarding,
        ], forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class AppModel {
    let store: Store

    var threads: [WorkThread] = []
    var proposals: [ThreadProposal] = []
    var recentTabs: [BrowserContext] = []
    var recentCode: [CodeContext] = []

    var route: Route = .now
    var searchText = ""
    var searchResults: [SearchHit] = []

    var scanState: ScanState = .idle
    var consent = ConsentSettings.load()
    var toast: Toast?
    var loadFailure: String?

    /// True while the very first load is in flight, so the window shows a
    /// loading state rather than an empty one it will immediately replace.
    var isLoading = true

    /// Endpoint the browser extension and CLI talk to. Off until the user turns
    /// it on, like every other integration.
    private var server: LocalServer?
    var serverPort: UInt16?
    var serverError: String?

    /// How the quick-capture panel is summoned. Changing it re-registers the
    /// trigger immediately; `shortcutFailure` says so when the system refuses.
    var captureTrigger = CaptureTrigger.load() {
        didSet { captureTrigger.save() }
    }
    var shortcutFailure: String?

    // MARK: - Recording

    /// Whether FlowTrace is watching what you do. Off until switched on — the
    /// timeline is empty and says so rather than capturing first and asking later.
    var isRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "flowtrace.recording") }
        set {
            UserDefaults.standard.set(newValue, forKey: "flowtrace.recording")
            newValue ? recorder.start() : recorder.stop()
        }
    }

    /// Not observed: the recorder is machinery, and its identity never changes,
    /// so it must not participate in view invalidation.
    @ObservationIgnored private var _recorder: ActivityRecorder?

    var recorder: ActivityRecorder {
        if let _recorder { return _recorder }
        let made = ActivityRecorder(store: store)
        _recorder = made
        return made
    }

    func startRecordingIfEnabled() {
        if isRecording { recorder.start() }
        importSessions()

        // Ambient events exist to give the capture panel something to say about
        // what led here. Past a couple of days they are only taking up space.
        let store = self.store
        Task.detached(priority: .background) {
            _ = try? store.pruneAmbientActivity()
        }
    }

    /// Bumped whenever the day changes, so the timeline and the rail refresh
    /// together without either polling the other.
    var activityRevision = 0

    /// Folds today's agent transcripts into the day. Cheap and idempotent, so it
    /// runs on launch and on a slow timer rather than needing to be exact.
    func importSessions(on day: Date = Date()) {
        let store = self.store
        Task.detached(priority: .utility) {
            let cache = StoreSessionCache(store: store)
            let count = SessionImporter().importSessions(on: day, into: store, cache: cache)
            cache.flush()
            guard count > 0 else { return }
            await MainActor.run { [weak self] in self?.activityRevision += 1 }
        }
    }

    /// Bumped to force the trigger to re-register when nothing about it changed
    /// but the world did — notably when Accessibility is granted while the app
    /// is already running.
    var triggerReloadToken = 0

    func reregisterTrigger() { triggerReloadToken += 1 }

    /// The chord to use if the user switches back from a modifier tap, so the
    /// recorder doesn't forget what they had set.
    var lastChord = HotKeyShortcut.load() {
        didSet { lastChord.save() }
    }

    var localServerEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "flowtrace.localServer") }
        set {
            UserDefaults.standard.set(newValue, forKey: "flowtrace.localServer")
            newValue ? startServer() : stopServer()
        }
    }

    init(store: Store) {
        self.store = store
    }

    // MARK: - Local endpoint

    func startServerIfEnabled() {
        if localServerEnabled { startServer() }
    }

    /// Brings up the capture endpoint off the main actor.
    ///
    /// Token lookup touches the keychain, which can be slow or fail outright on an
    /// ad-hoc signed build. None of that is allowed to delay the window.
    private func startServer() {
        guard server == nil else { return }
        let server = LocalServer(store: store)
        server.onCapture = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        server.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.serverError = message
                self?.serverPort = nil
            }
        }
        self.server = server
        Task.detached(priority: .utility) { [weak self] in
            do {
                try server.start()
                await MainActor.run { [weak self] in
                    self?.serverError = nil
                    self?.serverPort = server.port
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.serverError = error.localizedDescription
                    self?.server = nil
                }
            }
        }
    }

    private func stopServer() {
        server?.stop()
        server = nil
        serverPort = nil
    }

    func localAPIToken() -> String {
        (try? LocalCredentials.token()) ?? ""
    }

    func regenerateLocalAPIToken() {
        do {
            _ = try LocalCredentials.regenerate()
            if localServerEnabled { stopServer(); startServer() }
            toast = Toast(message: "New token — re-pair the extension")
        } catch {
            toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Loading

    func refresh() {
        do {
            threads = try store.allThreads()
            proposals = consent.anyEnabled ? try store.pendingProposals() : []
            recentTabs = try store.recentTabs(limit: 30)
            recentCode = try store.recentCodeContexts(limit: 30)
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Derived views of the data

    var activeThreads: [WorkThread] { threads.filter { $0.status == .active } }
    var pausedThreads: [WorkThread] { threads.filter { $0.status == .paused } }
    var completedThreads: [WorkThread] { threads.filter { $0.status == .completed } }
    var blockedThreads: [WorkThread] { threads.filter { $0.isBlocked && $0.status != .completed } }

    /// What to offer first on return: whatever was touched most recently and
    /// isn't finished.
    var continueWhereYouLeftOff: [WorkThread] {
        threads
            .filter { $0.status != .completed }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(3)
            .map { $0 }
    }

    func threads(for status: ThreadStatus) -> [WorkThread] {
        threads.filter { $0.status == status }
    }

    func thread(id: String) -> WorkThread? {
        threads.first { $0.id == id }
    }

    func linkCounts(for threadId: String) -> (tabs: Int, code: Int) {
        (
            recentTabs.filter { $0.workThreadId == threadId }.count,
            recentCode.filter { $0.workThreadId == threadId }.count
        )
    }

    // MARK: - Thread actions

    func create(title: String, intent: String, nextStep: String, priority: Priority) {
        perform("Couldn't create the thread") {
            let thread = try store.create(WorkThread(
                title: title, intent: intent, nextStep: nextStep, priority: priority
            ))
            refresh()
            route = .thread(thread.id)
            toast = Toast(message: "Created \"\(thread.title)\"")
        }
    }

    func update(_ thread: WorkThread, announce: String? = nil) {
        perform("Couldn't save your changes") {
            _ = try store.update(thread)
            refresh()
            if let announce { toast = Toast(message: announce) }
        }
    }

    func resume(_ threadId: String) {
        perform("Couldn't resume that thread") {
            _ = try store.resume(threadId: threadId)
            refresh()
            route = .thread(threadId)
        }
    }

    func setStatus(_ status: ThreadStatus, for threadId: String) {
        perform("Couldn't change the status") {
            _ = try store.setStatus(status, threadId: threadId)
            refresh()
            toast = Toast(message: "Marked \(status.label.lowercased())")
        }
    }

    func delete(threadId: String) {
        perform("Couldn't delete that thread") {
            try store.delete(threadId: threadId)
            refresh()
            route = .dashboard
            toast = Toast(message: "Thread deleted")
        }
    }

    // MARK: - Proposals

    func accept(_ proposal: ThreadProposal, edited: (title: String, intent: String, nextStep: String)?) {
        perform("Couldn't create a thread from that") {
            let thread = try store.accept(proposal: proposal, edited: edited)
            refresh()
            toast = Toast(message: "Added \"\(thread.title)\"")
        }
    }

    func dismiss(_ proposal: ThreadProposal, ignoreRepository: Bool = false) {
        perform("Couldn't dismiss that") {
            try store.dismiss(proposal: proposal, ignorePathEntirely: ignoreRepository)
            refresh()
            toast = Toast(message: ignoreRepository
                ? "Ignoring \(proposal.evidence.repositoryName)"
                : "Dismissed")
        }
    }

    // MARK: - Scanning

    func scan() {
        guard consent.anyEnabled, !scanState.isRunning else { return }

        var adapters: [any AgentAdapter] = []
        if consent.claudeCode { adapters.append(ClaudeCodeAdapter()) }
        if consent.codex { adapters.append(CodexAdapter()) }

        scanState = .running(phase: "Starting", fraction: 0)
        let store = self.store

        Task.detached(priority: .userInitiated) {
            do {
                let cache = StoreSessionCache(store: store)
                let ignored = try store.ignoredPaths()
                let detector = AbandonedWorkDetector(
                    adapters: adapters, cache: cache, ignoredPaths: ignored
                )

                let result = try detector.scan { progress in
                    let fraction = progress.total > 0
                        ? Double(progress.completed) / Double(progress.total)
                        : 0
                    Task { @MainActor [weak self] in
                        self?.scanState = .running(phase: progress.phase, fraction: fraction)
                    }
                }
                cache.flush()
                _ = try store.mergeProposals(result.proposals)

                await MainActor.run { [weak self] in
                    self?.scanState = .finished(.init(
                        proposals: result.proposals.count,
                        sessions: result.sessionsScanned,
                        repositories: result.repositoriesProbed,
                        duration: result.duration
                    ))
                    self?.refresh()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.scanState = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Search

    func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { searchResults = []; return }
        searchResults = (try? store.search(query, limit: 60)) ?? []
    }

    // MARK: - Errors

    /// Every mutation goes through here so a failure surfaces as a message the
    /// user can read, never as a silent no-op.
    private func perform(_ context: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            toast = Toast(message: "\(context): \(error.localizedDescription)", isError: true)
        }
    }
}
