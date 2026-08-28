import SwiftUI
import AppKit
import FlowTraceCore

/// "Why am I here?" — answered where you are, so you never have to come back to
/// the app to write it down.
///
/// The note lands on the timeline entry for what you are doing *right now*. That
/// is the whole point: the day fills in from wherever you happen to be.
struct QuickCaptureView: View {
    @Bindable var model: AppModel
    let snapshot: FrontmostSnapshot
    let onFinish: () -> Void

    @State private var resolved: FrontmostSnapshot
    @State private var current: ActivityEvent?
    @State private var leadingUp: [ActivityEvent] = []
    @State private var note = ""
    @State private var saved = false
    @FocusState private var focused: Bool

    init(model: AppModel, snapshot: FrontmostSnapshot, onFinish: @escaping () -> Void) {
        self.model = model
        self.snapshot = snapshot
        self.onFinish = onFinish
        _resolved = State(initialValue: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            header
            if saved { confirmation } else { editor }
            if !leadingUp.isEmpty, !saved { context }
        }
        .padding(Journal.Space.l)
        .frame(width: 520, alignment: .leading)
        .background(Journal.card)
        .onAppear(perform: load)
    }

    // MARK: - Where you are

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text("Right now")
                    .font(.observed(10.5, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Journal.pen)

                Spacer()

                // Escape works, but a panel with no visible way out reads as a
                // thing that has taken over rather than one you summoned.
                Button(action: onFinish) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Journal.inkSoft)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close without writing anything (esc)")
            }

            Text(resolved.summary)
                .font(.journalTitle(22))
                .foregroundStyle(Journal.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Text(resolved.appName)
                if let detail = resolved.detail {
                    Text("·").foregroundStyle(Journal.ruleFirm)
                    Text(detail)
                }
                if resolved.openTabCount > 1 {
                    Text("·").foregroundStyle(Journal.ruleFirm)
                    Text("\(resolved.openTabCount) tabs open")
                }
                if let current, current.isOpen {
                    Text("·").foregroundStyle(Journal.ruleFirm)
                    Text(current.durationLabel)
                }
            }
            .font(.observed(11.5))
            .foregroundStyle(Journal.inkSoft)

            if resolved.automationDenied { automationNotice }
        }
    }

    /// A browser FlowTrace has never been granted access to looks exactly like a
    /// browser with no tabs. Saying so, with the fix attached, is the difference
    /// between a bug and a setup step.
    private var automationNotice: some View {
        HStack(spacing: Journal.Space.s) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Journal.amber)
            Text("FlowTrace can't read \(resolved.appName)'s tabs yet")
                .font(.observed(11.5))
                .foregroundStyle(Journal.amber)
            Spacer()
            Button("Allow…") {
                AutomationPermission.openSettings()
            }
            .buttonStyle(.plain)
            .font(.observed(11, weight: .medium))
            .foregroundStyle(Journal.pen)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 5)
    }

    // MARK: - The one field

    private var editor: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            TextField("why are you here?", text: $note)
                .textFieldStyle(.plain)
                .font(.yourWords(17))
                .foregroundStyle(Journal.ink)
                .focused($focused)
                .onSubmit(save)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Journal.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Journal.pen, lineWidth: 1)
                )

            HStack(spacing: Journal.Space.s) {
                Text("⏎ save").font(.observed(10.5)).foregroundStyle(Journal.inkSoft)
                Text("esc cancel").font(.observed(10.5)).foregroundStyle(Journal.inkSoft)
                Spacer()
                Text(model.captureTrigger.displayString)
                    .font(.observed(10.5, weight: .medium))
                    .foregroundStyle(Journal.pen)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .background {
            Button("", action: onFinish)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    /// What led here. Pre-existing context is what turns a blank box into a
    /// prompt you only have to confirm.
    private var context: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Just before this")
                .font(.observed(10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Journal.inkSoft)

            ForEach(leadingUp) { event in
                HStack(alignment: .top, spacing: 7) {
                    Text(event.startedAt, format: .dateTime.hour().minute())
                        .font(.observed(10.5)).monospacedDigit()
                        .foregroundStyle(Journal.inkSoft)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(event.target.map { "\(event.appName) · \($0)" } ?? event.appName)
                            .font(.observed(12))
                            .foregroundStyle(Journal.inkMid)
                            .lineLimit(1)
                        if let note = event.note, !note.isEmpty {
                            Text("“\(note)”")
                                .font(.yourWords(12.5))
                                .foregroundStyle(Journal.inkMid)
                                .lineLimit(1)
                        } else if let asked = event.metadata["asked"]?
                            .split(separator: "\n").last {
                            Text(String(asked))
                                .font(.yourWords(12.5))
                                .foregroundStyle(Journal.inkSoft)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.top, Journal.Space.xs)
    }

    private var confirmation: some View {
        HStack(spacing: Journal.Space.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Journal.pen)
            Text("Written down.").font(.observed(13)).foregroundStyle(Journal.ink)
            Spacer()
        }
        .padding(.vertical, Journal.Space.s)
    }

    // MARK: - Actions

    private func load() {
        focused = true
        current = try? model.store.openActivity()
        leadingUp = (try? model.store.activityLeadingUp(to: Date())) ?? []
        note = current?.note ?? ""

        // Enrich with the browser tab a moment later, so the panel appears at once.
        let snapshot = self.snapshot
        Task.detached(priority: .userInitiated) {
            let enriched = snapshot.resolvingBrowserTab()
            await MainActor.run { if enriched != snapshot { resolved = enriched } }
        }
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { onFinish(); return }

        do {
            // Annotate the span you are inside. If the recorder isn't running
            // there is nothing to annotate, so make the entry too — a note should
            // never be lost because capture happened to be off.
            let target: ActivityEvent
            if let current {
                // The span may have been opened before the tab could be read —
                // the note should still land on the page, not on "Brave Browser".
                if current.url == nil, let url = resolved.url {
                    try model.store.describeActivity(
                        id: current.id, target: resolved.pageTitle, url: url
                    )
                }
                target = current
            } else {
                target = try model.store.beginActivity(ActivityEvent(
                    kind: resolved.url != nil ? .browserTab : .app,
                    startedAt: Date(),
                    appName: resolved.appName,
                    bundleIdentifier: resolved.bundleIdentifier,
                    target: resolved.pageTitle,
                    url: resolved.url,
                    metadata: resolved.openTabCount > 1
                        ? ["tabsOpen": String(resolved.openTabCount)] : [:]
                ))
            }

            _ = try model.store.annotate(activityId: target.id, note: text)
            model.refresh()
            saved = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                onFinish()
            }
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
            onFinish()
        }
    }
}
