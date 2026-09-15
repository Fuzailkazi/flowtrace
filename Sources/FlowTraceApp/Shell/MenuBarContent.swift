import SwiftUI
import FlowTraceCore

// MARK: - Menu bar

/// The popover under the menu bar glyph. No dedicated Stitch screen exists for
/// it, so it borrows the design's tokens and card language and keeps every
/// action it had: the capture key, the legacy capture doors, open, quit.
struct MenuBarContent: View {
    @Bindable var model: AppModel

    /// Opens the main window by name. It is not created at launch any more, so
    /// there may be nothing to raise.
    @Environment(\.openWindow) private var openWindow

    /// What is actually running, read once each time the popover opens.
    ///
    /// The same `LiveStateReader` the Now screen uses — the menu bar is the
    /// surface people keep open, so it should answer the same question Now
    /// answers rather than only listing threads.
    @State private var projects: [LiveProject] = []
    @State private var agentCount = 0
    @State private var serverCount = 0
    @State private var loadingLive = true

    private var forgotten: [LiveProject] { projects.filter(\.isForgotten) }

    var body: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack(spacing: 10) {
                BrandMarkView(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FlowTrace")
                        .font(.journalTitle(13))
                        .foregroundStyle(Journal.ink)
                    Text("Local only")
                        .font(.caption(10))
                        .foregroundStyle(Journal.inkSoft)
                }
                Spacer()
            }

            // The popover is the only FlowTrace surface most days, and it is
            // the one place a broken database would otherwise look exactly
            // like a quiet week.
            if let failure = model.loadFailure {
                card {
                    VStack(alignment: .leading, spacing: 2) {
                        LoadFailureLine(message: "Couldn't read your work")
                        Text(failure)
                            .font(.observed(10.5))
                            .foregroundStyle(Journal.inkMid)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            liveState

            if !model.proposals.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.proposals.count) unfinished")
                            .font(.observed(13, weight: .semibold))
                            .foregroundStyle(Journal.ink)
                        Text("found across your repositories")
                            .font(.observed(11)).foregroundStyle(Journal.inkMid)
                    }
                }
            }

            if let latest = model.continueWhereYouLeftOff.first {
                card {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CONTINUE WHERE YOU LEFT OFF")
                            .font(.caption(10)).tracking(1.0)
                            .foregroundStyle(Journal.inkSoft)
                        Text(latest.title)
                            .font(.observed(12, weight: .medium))
                            .foregroundStyle(Journal.ink)
                            .lineLimit(1)
                        if !latest.nextStep.isEmpty {
                            Text(latest.nextStep)
                                .font(.observed(11)).foregroundStyle(Journal.inkMid).lineLimit(2)
                        }
                        Button("Resume") {
                            model.resume(latest.id)
                            activate()
                        }
                        .buttonStyle(.plain)
                        .font(.observed(11, weight: .medium))
                        .foregroundStyle(Journal.pen)
                        .padding(.top, 2)
                    }
                }
            }

            // The one action that matters, styled as the design's primary button.
            Button {
                NotificationCenter.default.post(name: .flowtraceQuickCapture, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill").font(.system(size: 11, weight: .semibold))
                    Text("Why am I here?")
                        .font(.observed(12.5, weight: .semibold))
                    Spacer()
                    Text(model.captureTrigger.displayString)
                        .font(.mono(10.5))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Journal.onPen)
                }
                .foregroundStyle(Journal.onPen)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Journal.pen, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                row("Capture context…", symbol: "tray.and.arrow.down") {
                    activate()
                    NotificationCenter.default.post(name: .flowtraceCapture, object: nil)
                }
                row("New work thread", symbol: "plus") {
                    activate()
                    NotificationCenter.default.post(name: .flowtraceNewThread, object: nil)
                }
                row("Open FlowTrace", symbol: "macwindow") { activate() }
            }

            Divider().overlay(Journal.rule)

            row("Quit FlowTrace", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(Journal.Space.m)
        .frame(width: 272)
        .background(Journal.paper)
        .task {
            model.refresh()
            await readLive()
        }
    }

    /// Running agents and servers, and what has been left behind.
    @ViewBuilder
    private var liveState: some View {
        if loadingLive && projects.isEmpty {
            HStack {
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, Journal.Space.xs)
        } else if projects.isEmpty {
            Text("Nothing running.")
                .font(.observed(12))
                .foregroundStyle(Journal.inkMid)
        } else {
            VStack(alignment: .leading, spacing: Journal.Space.s) {
                HStack(spacing: 6) {
                    Text("\(agentCount) agent\(agentCount == 1 ? "" : "s") · \(serverCount) server\(serverCount == 1 ? "" : "s")")
                        .font(.observed(12, weight: .semibold))
                        .foregroundStyle(Journal.ink)
                    Spacer()
                    if !forgotten.isEmpty {
                        Text("\(forgotten.count) forgotten")
                            .font(.caption(10))
                            .foregroundStyle(Journal.amber)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Journal.amberSoft, in: Capsule())
                    }
                }

                // The three worth knowing about: what has been left running
                // first, then whatever moved most recently.
                let shown = (forgotten + projects.filter { !$0.isForgotten }).prefix(3)
                ForEach(Array(shown)) { project in
                    HStack(spacing: Journal.Space.s) {
                        Circle()
                            .fill(project.isForgotten ? Journal.ruleFirm : Journal.live)
                            .frame(width: 6, height: 6)
                        Text(project.name)
                            .font(.observed(11.5))
                            .foregroundStyle(Journal.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(project.statusLabel)
                            .font(.caption(10))
                            .foregroundStyle(Journal.inkSoft)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// Process inspection shells out, so it never runs on the main actor.
    private func readLive() async {
        // The popover is a surface like any other: before consent it observes
        // nothing either.
        guard model.mayObserve else { loadingLive = false; return }
        let sources = model.readableSources
        let notes = model.store
        let read = await Task.detached(priority: .userInitiated) {
            () -> (LiveState, [String: ProjectNote], Set<String>) in
            let live = LiveStateReader().read(transcripts: sources)
            let projectNotes = (try? notes.allProjectNotes()) ?? []
            let ignored = (try? notes.ignoredPaths()) ?? []
            return (
                live,
                Dictionary(uniqueKeysWithValues: projectNotes.map { ($0.repositoryPath, $0) }),
                ignored
            )
        }.value

        projects = read.0.projects(notes: read.1).filter { !read.2.contains($0.path) }
        agentCount = projects.reduce(0) { $0 + $1.agents.count }
        serverCount = projects.reduce(0) { $0 + $1.servers.count }
        loadingLive = false
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Journal.Radius.field).strokeBorder(Journal.rule, lineWidth: 0.5))
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Journal.inkSoft)
                    .frame(width: 16)
                Text(title).font(.observed(12)).foregroundStyle(Journal.ink)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activate() {
        // Opening the workspace is a deliberate act, so FlowTrace takes on a
        // normal application identity first — Dock tile, menu, ⌘-Tab — and only
        // then puts the window on screen.
        let lifecycle = NSApplication.shared.delegate as? AppLifecycle
        lifecycle?.enterWorkspace()
        // The main window is no longer created at launch, so raising an
        // existing one is not enough — `openWindow` reuses it when it is open
        // and builds it when it is not.
        if lifecycle?.raiseMainWindow() != true {
            openWindow(id: FlowTraceApp.mainWindowID)
        }
    }
}
