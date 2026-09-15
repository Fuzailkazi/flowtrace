import SwiftUI
import AppKit
import FlowTraceCore

@main
struct FlowTraceApp: App {
    /// Keeps the app — and therefore the capture shortcut — alive when the
    /// window is closed.
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

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
            let model = AppModel(store: try Store())
            // The delegate owns the capture shortcut and the observation
            // lifecycle, both of which have to outlive the main window.
            MainActor.assumeIsolated { AppLifecycle.model = model }
            _launch = State(initialValue: .ready(model))
        } catch {
            _launch = State(initialValue: .failed(error.localizedDescription))
        }
    }

    /// The main window's identifier, so the menu bar can open it by name once
    /// it is no longer created at launch.
    static let mainWindowID = "flowtrace.main"

    var body: some Scene {
        // `Window`, not `WindowGroup`. A group exists to make many windows, and
        // `openWindow(id:)` on one dutifully builds another every time it is
        // called — which produced a second workspace on the second click. There
        // is exactly one FlowTrace workspace, so the scene that says so is the
        // one to use: `openWindow` re-shows the window it already has.
        Window("FlowTrace", id: FlowTraceApp.mainWindowID) {
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
        // The standard titlebar is a grey band that doesn't match warm paper,
        // and it read as a seam across the top of the window.
        .windowStyle(.hiddenTitleBar)
        .commands { FlowTraceCommands(model: launch.model) }

        MenuBarExtra {
            if let model = launch.model {
                MenuBarContent(model: model)
            } else {
                Button("Quit FlowTrace") { NSApplication.shared.terminate(nil) }
            }
        } label: {
            // The label lives for as long as the app does, which makes it the
            // one place that can hand `openWindow` to the delegate. Everything
            // else — the popover, the workspace itself — comes and goes.
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let model = launch.model {
                SettingsView(model: model).frame(width: 560, height: 520)
            }
        }
    }
}

/// The menu-bar item's face, and the app's only permanently live view.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: BrandMark.menuBarImage())
            .task {
                AppLifecycle.shared?.openWindowAction = {
                    openWindow(id: FlowTraceApp.mainWindowID)
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
            // Development only: force light or dark for this process so both
            // appearances can be checked against the design without changing
            // the system setting.
            switch ProcessInfo.processInfo.environment["FLOWTRACE_APPEARANCE"] {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            // Starting the model, the recorder and the capture shortcut is
            // `AppLifecycle`'s job now: this view only exists while the main
            // window is open, and none of that may depend on a window.
            model.refresh()
            // Lets `flowtrace resume <thread> --open` land straight on a thread.
            if let requested = ProcessInfo.processInfo.environment["FLOWTRACE_OPEN_THREAD"],
               model.thread(id: requested) != nil {
                model.route = .thread(requested)
            }
            // Development only: open on a given screen, so each one can be
            // launched and screenshotted without clicking through. Never set
            // by the app itself; harmless when absent.
            if let requested = ProcessInfo.processInfo.environment["FLOWTRACE_OPEN_ROUTE"] {
                switch requested {
                case "now": model.route = .now
                case "timeline": model.route = .timeline
                case "memories": model.route = .memories
                case "settings": model.route = .settings
                case "capture":
                    // Summon the panel a beat after launch, as the key would.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        NotificationCenter.default.post(name: .flowtraceQuickCapture, object: nil)
                    }
                case "memory:first":
                    if let newest = try? model.store.notedActivity(limit: 1).first {
                        model.route = .memory(newest.id)
                    }
                default:
                    if requested.hasPrefix("place:") {
                        var path = String(requested.dropFirst("place:".count))
                        // `place:<path>+capture` opens the place and then
                        // summons the panel, as pressing the key there would.
                        // The only way to exercise the contextual capture
                        // without a trusted process to post the keystroke.
                        let thenCapture = path.hasSuffix("+capture")
                        if thenCapture { path = String(path.dropLast("+capture".count)) }
                        model.route = .place(path)
                        if thenCapture {
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                NotificationCenter.default.post(
                                    name: .flowtraceQuickCapture, object: nil
                                )
                            }
                        }
                    } else if requested.hasPrefix("memory:") {
                        model.route = .memory(String(requested.dropFirst("memory:".count)))
                    }
                }
            }
        }
        .sheet(isPresented: .constant(!model.consent.hasCompletedOnboarding && !Self.devSkipsOnboarding)) {
            OnboardingView(model: model)
                .frame(width: 640, height: 560)
                .interactiveDismissDisabled()
        }
    }

    /// Development only: `FLOWTRACE_SKIP_ONBOARDING=1` keeps the first-run sheet
    /// down for this process so screens can be screenshotted. Nothing is saved;
    /// the next normal launch shows the sheet again.
    private static var devSkipsOnboarding: Bool {
        ProcessInfo.processInfo.environment["FLOWTRACE_SKIP_ONBOARDING"] == "1"
    }

}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var showingCapture = false
    @State private var showingNewThread = false

    var body: some View {
        NavigationSplitView {
            AppSidebar(model: model)
                .navigationSplitViewColumnWidth(min: Journal.sidebarWidth, ideal: Journal.sidebarWidth, max: Journal.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            DetailPane(model: model)
                .background(Journal.paper)
                .toolbar { chrome }
        }
        .navigationSplitViewStyle(.balanced)
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
        // Re-reads every colour when the theme changes.
        .id(model.paletteRevision)
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
        ToolbarItem(placement: .navigation) {
            // The design's "Private Session" chip, worded truthfully.
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                Text("Local only").font(.observed(11, weight: .medium))
            }
            .foregroundStyle(Journal.inkSoft)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
        }

        ToolbarItemGroup {
            Spacer()

            Menu {
                Button("Now") { model.route = .now }
                Button("Timeline") { model.route = .timeline }
                Button("Memories") { model.route = .memories }
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
            case .now:
                NowView(model: model)
            case .timeline:
                TimelineView(model: model)
            case .memories:
                MemoriesView(model: model)
            case .memory(let id):
                MemoryDetailView(model: model, eventId: id)
            case .place(let path):
                PlaceRecallView(model: model, path: path)
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

            Button("Why am I here?…") {
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
