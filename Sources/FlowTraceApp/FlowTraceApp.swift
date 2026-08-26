import SwiftUI
import FlowTraceCore

@main
struct FlowTraceApp: App {
    @State private var model: AppModel
    @State private var startupError: String?

    init() {
        do {
            let store = try Store()
            _model = State(initialValue: AppModel(store: store))
        } catch {
            // The database is the whole app; if it can't open, say so plainly
            // rather than launching into a window that silently does nothing.
            _model = State(initialValue: AppModel(store: try! Store(
                database: try! FlowTraceDatabase.inMemory()
            )))
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model, startupError: startupError)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1120, height: 720)
        .commands { FlowTraceCommands(model: model) }

        MenuBarExtra("FlowTrace", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            MenuBarContent(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .frame(width: 560, height: 520)
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Bindable var model: AppModel
    var startupError: String?
    @State private var hotKey: GlobalHotKey?

    var body: some View {
        Group {
            if let startupError {
                EmptyState(
                    icon: "externaldrive.badge.exclamationmark",
                    title: "FlowTrace couldn't open its database",
                    message: startupError
                )
            } else if model.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MainWindow(model: model)
            }
        }
        .task {
            model.refresh()
            model.startServerIfEnabled()
            registerHotKey()
            // Lets `flowtrace resume <thread> --open` land straight on a thread.
            if let requested = ProcessInfo.processInfo.environment["FLOWTRACE_OPEN_THREAD"],
               model.thread(id: requested) != nil {
                model.route = .thread(requested)
            }
        }
        .sheet(isPresented: .constant(!model.consent.hasCompletedOnboarding && startupError == nil)) {
            OnboardingView(model: model)
                .frame(width: 640, height: 560)
                .interactiveDismissDisabled()
        }
    }

    /// ⌥Space from anywhere opens capture. Silently skipped if another app
    /// already owns the combination.
    private func registerHotKey() {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .flowtraceCapture, object: nil)
        }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var showingCapture = false
    @State private var showingNewThread = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            DetailPane(model: model)
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search threads, tabs, repositories")
        .onChange(of: model.searchText) { _, _ in model.runSearch() }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingNewThread = true
                } label: {
                    Label("New Thread", systemImage: "plus")
                }
                .help("New work thread (⌘N)")

                Button {
                    showingCapture = true
                } label: {
                    Label("Capture", systemImage: "square.and.arrow.down")
                }
                .help("Capture browser tabs or a repository (⌘⇧C)")
            }
        }
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
        .background(Theme.pageBackground)
        .onReceive(NotificationCenter.default.publisher(for: .flowtraceNewThread)) { _ in
            showingNewThread = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .flowtraceCapture)) { _ in
            showingCapture = true
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
}

struct FlowTraceCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Work Thread") {
                NotificationCenter.default.post(name: .flowtraceNewThread, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Capture Context…") {
                NotificationCenter.default.post(name: .flowtraceCapture, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandMenu("Threads") {
            Button("Dashboard") { model.route = .dashboard }
                .keyboardShortcut("0", modifiers: .command)
            Button("Active") { model.route = .status(.active) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Paused") { model.route = .status(.paused) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Completed") { model.route = .status(.completed) }
                .keyboardShortcut("3", modifiers: .command)
            Divider()
            Button("Scan for unfinished work") { model.scan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.consent.anyEnabled)
        }
    }
}
