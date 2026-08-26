import SwiftUI
import FlowTraceCore

@main
struct FlowTraceApp: App {
    /// The database is the whole app. If it can't be opened there is no model to
    /// build, so that is a state the UI renders rather than a placeholder model
    /// standing in for one.
    private enum Launch {
        case ready(AppModel)
        case failed(String)

        var model: AppModel? {
            if case .ready(let model) = self { return model }
            return nil
        }
    }

    @State private var launch: Launch

    init() {
        do {
            _launch = State(initialValue: .ready(AppModel(store: try Store())))
        } catch {
            _launch = State(initialValue: .failed(error.localizedDescription))
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch launch {
                case .ready(let model):
                    RootView(model: model)
                case .failed(let message):
                    DatabaseUnavailableView(message: message)
                }
            }
            .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .commands { FlowTraceCommands(model: launch.model) }

        MenuBarExtra("FlowTrace", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            if let model = launch.model {
                MenuBarContent(model: model)
            } else {
                Button("Quit FlowTrace") { NSApplication.shared.terminate(nil) }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let model = launch.model {
                SettingsView(model: model).frame(width: 560, height: 520)
            }
        }
    }
}

/// Shown instead of the main window when the database can't be opened, with the
/// one thing the user can actually act on: where the file is.
struct DatabaseUnavailableView: View {
    let message: String

    var body: some View {
        EmptyState(
            icon: "externaldrive.badge.exclamationmark",
            title: "FlowTrace couldn't open its database",
            message: "\(message)\n\n\(FlowTraceDatabase.defaultURL.path.abbreviatingHome)",
            actionLabel: "Reveal in Finder",
            action: {
                NSWorkspace.shared.activateFileViewerSelecting([FlowTraceDatabase.defaultURL])
            }
        )
    }
}

// MARK: - Root

struct RootView: View {
    @Bindable var model: AppModel
    @State private var hotKey: GlobalHotKey?
    @State private var quickCapture: QuickCaptureController?
    @State private var tapMonitor: ModifierTapMonitor?

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MainWindow(model: model)
            }
        }
        .task {
            model.refresh()
            model.startServerIfEnabled()
            model.startRecordingIfEnabled()
            registerHotKey()
            // Lets `flowtrace resume <thread> --open` land straight on a thread.
            if let requested = ProcessInfo.processInfo.environment["FLOWTRACE_OPEN_THREAD"],
               model.thread(id: requested) != nil {
                model.route = .thread(requested)
            }
        }
        .onChange(of: model.captureTrigger) { _, updated in
            guard let controller = quickCapture else { return }
            registerTrigger(updated, controller: controller)
        }
        .onChange(of: model.triggerReloadToken) { _, _ in
            guard let controller = quickCapture else { return }
            registerTrigger(model.captureTrigger, controller: controller)
        }
        .sheet(isPresented: .constant(!model.consent.hasCompletedOnboarding)) {
            OnboardingView(model: model)
                .frame(width: 640, height: 560)
                .interactiveDismissDisabled()
        }
    }

    /// ⌥Space opens a small panel over whatever you are doing.
    ///
    /// It deliberately does not bring FlowTrace to the front: being thrown into
    /// another app is exactly the interruption that stops people capturing
    /// anything. Silently skipped if another app already owns the combination.
    private func registerHotKey() {
        guard hotKey == nil else { return }
        let controller = QuickCaptureController(model: model)
        quickCapture = controller
        registerTrigger(model.captureTrigger, controller: controller)

        // Same panel, reachable from the menubar for anyone who hasn't learned
        // the shortcut yet.
        NotificationCenter.default.addObserver(
            forName: .flowtraceQuickCapture, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in controller.toggle() }
        }
    }

    /// Claims the trigger, replacing whatever was registered before, and reports
    /// back whether the system accepted it.
    private func registerTrigger(_ trigger: CaptureTrigger, controller: QuickCaptureController) {
        // Release both mechanisms first: Carbon will not hand over a combination
        // still claimed by this process, and a stale monitor would double-fire.
        hotKey = nil
        tapMonitor?.stop()
        tapMonitor = nil
        model.shortcutFailure = nil

        switch trigger {
        case .chord(let shortcut):
            let key = GlobalHotKey(shortcut: shortcut) {
                Task { @MainActor in controller.toggle() }
            }
            hotKey = key
            model.shortcutFailure = key.failure?.message
            Diagnostics.log(
                key.failure == nil
                    ? "trigger \(trigger.displayString) registered"
                    : "trigger \(trigger.displayString) FAILED — \(key.failure!.message)"
            )

        case .modifierTap(let modifier, let taps):
            // Without Accessibility we cannot see keys pressed in other apps, so
            // say that plainly rather than leaving a dead trigger.
            guard AccessibilityPermission.isGranted else {
                model.shortcutFailure =
                    "Tapping a modifier needs the Accessibility permission. "
                    + "Grant it below, then this starts working."
                Diagnostics.log("trigger \(trigger.displayString) blocked — no Accessibility")
                return
            }
            let monitor = ModifierTapMonitor(key: modifier, taps: taps) {
                Task { @MainActor in controller.toggle() }
            }
            monitor.start()
            tapMonitor = monitor
            Diagnostics.log("trigger \(trigger.displayString) watching")
        }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var showingCapture = false
    @State private var showingNewThread = false

    var body: some View {
        Group {
            // One screen. The sidebar that used to live here — All / Active /
            // Paused / Completed — was the grammar of a task manager, and it told
            // everyone the wrong thing about what this is.
            if model.route == .timeline {
                TimelineView(model: model)
            } else {
                DetailPane(model: model)
                    .background(Journal.paper)
            }
        }
        .toolbar { chrome }
        .sheet(isPresented: $showingCapture) { CaptureSheet(model: model) }
        .sheet(isPresented: $showingNewThread) { NewThreadSheet(model: model) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.bottom, Theme.Space.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.toast)
        .background(Journal.paper)
        .onReceive(NotificationCenter.default.publisher(for: .flowtraceNewThread)) { _ in
            showingNewThread = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowtraceCapture)) { _ in
            showingCapture = true
        }
    }

    /// Everything that isn't the day itself lives in one menu, so the window has
    /// a single subject.
    @ToolbarContentBuilder
    private var chrome: some ToolbarContent {
        ToolbarItemGroup {
            if model.route != .timeline {
                Button {
                    model.route = .timeline
                } label: {
                    Label("Today", systemImage: "chevron.left")
                }
                .help("Back to today")
            }

            Spacer()

            Menu {
                Button("Today") { model.route = .timeline }
                Divider()
                Button("Unfinished work") { model.route = .dashboard }
                Button("All threads") { model.route = .status(.active) }
                Button("Recent captures") { model.route = .recentCaptures }
                Divider()
                Button("Capture context…") { showingCapture = true }
                Button("New thread…") { showingNewThread = true }
                Divider()
                Button("Settings") { model.route = .settings }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Chooses what the main area shows: search results take priority whenever the
/// user is typing, otherwise the selected route.
struct DetailPane: View {
    @Bindable var model: AppModel

    var body: some View {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsView(model: model)
        } else {
            switch model.route {
            case .timeline:
                TimelineView(model: model)
            case .dashboard:
                DashboardView(model: model)
            case .status(let status):
                ThreadListView(model: model, status: status)
            case .thread(let id):
                if let thread = model.thread(id: id) {
                    ThreadDetailView(model: model, thread: thread)
                } else {
                    EmptyState(
                        icon: "questionmark.folder",
                        title: "That thread is gone",
                        message: "It may have been deleted.",
                        actionLabel: "Back to dashboard",
                        action: { model.route = .dashboard }
                    )
                }
            case .recentCaptures:
                RecentCapturesView(model: model)
            case .settings:
                SettingsView(model: model)
            }
        }
    }
}

// MARK: - Commands

extension Notification.Name {
    static let flowtraceNewThread = Notification.Name("flowtrace.newThread")
    static let flowtraceCapture = Notification.Name("flowtrace.capture")
    static let flowtraceQuickCapture = Notification.Name("flowtrace.quickCapture")
}

struct FlowTraceCommands: Commands {
    /// Absent when the database couldn't be opened; navigation commands are
    /// disabled rather than hidden, so the menus stay where the user expects.
    let model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Work Thread") {
                NotificationCenter.default.post(name: .flowtraceNewThread, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Why Am I Here?…") {
                NotificationCenter.default.post(name: .flowtraceQuickCapture, object: nil)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("Capture Context…") {
                NotificationCenter.default.post(name: .flowtraceCapture, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandMenu("Threads") {
            Button("Dashboard") { model?.route = .dashboard }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(model == nil)
            Button("Active") { model?.route = .status(.active) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(model == nil)
            Button("Paused") { model?.route = .status(.paused) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(model == nil)
            Button("Completed") { model?.route = .status(.completed) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(model == nil)
            Divider()
            Button("Scan for unfinished work") { model?.scan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!(model?.consent.anyEnabled ?? false))
        }
    }
}
