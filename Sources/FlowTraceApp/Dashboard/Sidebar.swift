import SwiftUI
import FlowTraceCore

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                row(.timeline, "Today", "text.line.first.and.arrowtriangle.forward",
                    badge: nil)
                row(.dashboard, "Resume", "arrow.uturn.backward.circle",
                    badge: model.proposals.isEmpty ? nil : model.proposals.count,
                    badgeIsAttention: true)
                row(.status(.active), "Active", "circle.fill", badge: nilIfZero(model.activeThreads.count))
                row(.status(.paused), "Paused", "pause.circle", badge: nilIfZero(model.pausedThreads.count))
                row(.status(.completed), "Completed", "checkmark.circle",
                    badge: nilIfZero(model.completedThreads.count))
            }

            Section("Captures") {
                row(.recentCaptures, "Recent Captures", "tray.full",
                    badge: nilIfZero(model.recentTabs.count + model.recentCode.count))
            }

            Section {
                row(.settings, "Settings", "gearshape")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { scanFooter }
    }

    private var selectionBinding: Binding<Route?> {
        Binding(
            get: { model.route },
            set: { newValue in if let newValue { model.route = newValue } }
        )
    }

    private func nilIfZero(_ value: Int) -> Int? { value == 0 ? nil : value }

    @ViewBuilder
    private func row(
        _ route: Route, _ title: String, _ icon: String,
        badge: Int? = nil, badgeIsAttention: Bool = false
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let badge {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badgeIsAttention ? .white : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        badgeIsAttention ? Color.accentColor : Color.secondary.opacity(0.15),
                        in: Capsule()
                    )
            }
        }
        .tag(route)
    }

    /// Scanning lives at the bottom of the sidebar because it is a background
    /// housekeeping action, not the thing the user came here to do.
    @ViewBuilder
    private var scanFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Divider()
            switch model.scanState {
            case .running(let phase, let fraction):
                VStack(alignment: .leading, spacing: 3) {
                    Text(phase).font(.system(size: 10)).foregroundStyle(.secondary)
                    ProgressView(value: fraction).controlSize(.small)
                }
                .padding(.horizontal, Theme.Space.m)
            default:
                Button {
                    model.scan()
                } label: {
                    Label("Scan for unfinished work", systemImage: "sparkle.magnifyingglass")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.consent.anyEnabled ? Color.accentColor : Color.secondary)
                .disabled(!model.consent.anyEnabled)
                .help(model.consent.anyEnabled
                      ? "Re-read agent sessions and git state (⌘⇧R)"
                      : "Turn on a source in Settings first")
                .padding(.horizontal, Theme.Space.m)
            }
        }
        .padding(.bottom, Theme.Space.s)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !model.proposals.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.proposals.count) unfinished")
                        .font(.system(size: 13, weight: .semibold))
                    Text("found across your repositories")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let latest = model.continueWhereYouLeftOff.first {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue where you left off")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(latest.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !latest.nextStep.isEmpty {
                        Text(latest.nextStep)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Button("Resume") {
                        model.resume(latest.id)
                        activate()
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }

            Divider()

            HStack {
                Button("Add a note here") {
                    NotificationCenter.default.post(name: .flowtraceQuickCapture, object: nil)
                }
                Spacer()
                Text(CaptureTrigger.hasBeenChosen
                     ? model.captureTrigger.displayString
                     : "set a key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CaptureTrigger.hasBeenChosen ? .secondary : Color.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(
                        CaptureTrigger.hasBeenChosen
                            ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            Button("Capture context…") {
                activate()
                NotificationCenter.default.post(name: .flowtraceCapture, object: nil)
            }
            Button("New work thread") {
                activate()
                NotificationCenter.default.post(name: .flowtraceNewThread, object: nil)
            }
            Button("Open FlowTrace") { activate() }

            Divider()
            Button("Quit FlowTrace") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.m)
        .frame(width: 260)
        .task { model.refresh() }
    }

    private func activate() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
