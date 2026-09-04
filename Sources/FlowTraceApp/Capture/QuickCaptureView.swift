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
    @State private var suggestion: CaptureSuggestion?
    @State private var note = ""
    @State private var saved = false
    @State private var plan: CapturePlan?
    /// What the field was pre-filled with, if anything. A note may only be
    /// overwritten if the user actually saw it.
    @State private var shownNote: String?
    @State private var enrichmentFinished = false
    @State private var saving = false
    @State private var saveError: String?
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
                Button(action: { if !saving { onFinish() } }) {
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
                if let current, current.isOpen, isAnnotatingOpenSpan {
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
                .onKeyPress(.tab) {
                    guard canAcceptSuggestion else { return .ignored }
                    acceptSuggestion()
                    return .handled
                }
                .onChange(of: note) { _, _ in saveError = nil }
                // `text` is captured before the save waits for the tab, so a
                // field still live through that wait would swallow anything
                // typed after Return and confirm the older sentence. `saving` is
                // set in the same main-actor turn as the keypress, so the field
                // goes inert with no window to type into.
                .disabled(saving)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Journal.paper, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Journal.pen, lineWidth: 1)
                )

            suggestionRow

            if let saveError {
                HStack(spacing: Journal.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Journal.amber)
                    Text(saveError)
                        .font(.observed(11.5))
                        .foregroundStyle(Journal.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: 6))
            }

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
            Button("") { if !saving { onFinish() } }
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

    // MARK: - Smart capture

    private var canAcceptSuggestion: Bool { note.isEmpty && suggestion != nil }

    /// Fills the field and selects the text, so typing replaces it outright —
    /// nothing is saved until Return is pressed. Reaching into the responder
    /// chain is necessary because a plain SwiftUI `TextField` doesn't expose the
    /// underlying `NSTextView` to select programmatically; the field already has
    /// focus (this is only reachable while it's focused and empty), so its field
    /// editor is the key window's first responder a moment after the text is set.
    private func acceptSuggestion() {
        guard let suggestion else { return }
        note = suggestion.text
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func suggestionLabel(_ suggestion: CaptureSuggestion) -> String {
        suggestion.source == .agentPrompt
            ? "Last asked: \"\(suggestion.text)\""
            : "\"\(suggestion.text)\""
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if canAcceptSuggestion, let suggestion {
            Button(action: acceptSuggestion) {
                HStack(spacing: 6) {
                    Text("💭")
                    Text(suggestionLabel(suggestion))
                        .font(.yourWords(12.5))
                        .foregroundStyle(Journal.inkMid)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("Tab to use")
                        .font(.observed(10.5, weight: .medium))
                        .foregroundStyle(Journal.inkSoft)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The currently-open activity's project, or — scanning newest-first — the
    /// first `leadingUp` event that has one. Stops at the first `cwd` found,
    /// whether or not a `ProjectNote` exists for it: this is a single best guess,
    /// not a search across every project mentioned in the last 20 minutes.
    private func projectNoteCandidate() -> String? {
        let cwd = current?.metadata["cwd"] ?? leadingUp.compactMap { $0.metadata["cwd"] }.first
        guard let cwd, !cwd.isEmpty else { return nil }
        return (try? model.store.projectNote(for: cwd))?.building
    }

    /// The most recent `leadingUp` event with something asked of an agent. Mirrors
    /// the `context` view below (`QuickCaptureView.swift:176-178`): `metadata["asked"]`
    /// can hold several newline-joined prompts, and only the last is shown.
    private func lastAgentPromptCandidate() -> String? {
        guard let raw = leadingUp.first(where: { !($0.metadata["asked"] ?? "").isEmpty })?.metadata["asked"],
              let lastLine = raw.split(separator: "\n").last
        else { return nil }
        return AgentSession.condense(String(lastLine))
    }

    /// Recomputes the suggestion. A no-op once the user has typed anything (by
    /// hand, or by accepting an earlier suggestion) — the row is already gone and
    /// should stay gone rather than reappearing with different text.
    private func recomputeSuggestion(tabNote: String?) {
        guard note.isEmpty else { return }
        suggestion = CaptureSuggester.suggest(CaptureSuggestionInput(
            projectNote: projectNoteCandidate(),
            tabNote: tabNote,
            lastAgentPrompt: lastAgentPromptCandidate()
        ))
    }

    // MARK: - Actions

    private func load() {
        focused = true
        current = try? model.store.openActivity()
        leadingUp = (try? model.store.activityLeadingUp(to: Date())) ?? []
        refreshPlan()
        // For a terminal or an editor this is the final answer, so the field is
        // filled before the panel draws rather than a beat later.
        if let prefill = CaptureTargeting.prefill(
            open: current, site: resolved.site, recording: model.recorder.isRunning
        ) {
            note = prefill
            shownNote = prefill
        }
        recomputeSuggestion(tabNote: nil)

        // The tab is read in two steps. Which tab you are on decides where the
        // note lands, so it is published the moment it is known; how many other
        // tabs are open is decoration, and walking the window for it is the
        // slow half.
        let snapshot = self.snapshot
        Task.detached(priority: .userInitiated) {
            let identified = snapshot.resolvingActiveTab()
            await MainActor.run {
                if identified != snapshot { resolved = identified }
                refreshPlan()
                if note.isEmpty, let prefill = CaptureTargeting.prefill(
                    open: current, site: resolved.site, recording: model.recorder.isRunning
                ) {
                    note = prefill
                    shownNote = prefill
                }
                if let url = identified.url {
                    recomputeSuggestion(tabNote: (try? model.store.noteForTab(url: url)) ?? nil)
                }
                // Everything the note's destination depends on is now known.
                enrichmentFinished = true
            }

            let counted = identified.resolvingTabCount()
            await MainActor.run { if counted != identified { resolved = counted } }
        }
    }

    private func refreshPlan() {
        plan = CaptureTargeting.plan(
            open: current, site: resolved.site,
            recording: model.recorder.isRunning, now: Date()
        )
    }

    private var isAnnotatingOpenSpan: Bool {
        if case .annotateOpen = plan { return true }
        return false
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { onFinish(); return }
        guard !saving else { return }
        saving = true
        saveError = nil

        Task { @MainActor in
            defer { saving = false }
            await waitForTab()

            do {
                // The load-time span can be seconds stale, and which tab you are
                // on may only just have arrived.
                current = try model.store.openActivity()
                refreshPlan()
                try write(text)

                model.refresh()
                saved = true
                try? await Task.sleep(for: .milliseconds(600))
                onFinish()
            } catch {
                Diagnostics.log("capture save failed: \(error)")
                saveError = "Couldn't write that down. Your words are still here — press Return to try again."
            }
        }
    }

    /// Waits for the tab to be identified, but not for long.
    ///
    /// A one-word note and a fast Return can beat the AppleScript round trip,
    /// and saving before the tab is known files the note on the page you left.
    /// A polled flag rather than awaiting the task: the read is a synchronous
    /// Apple Event whose own timeout is two minutes, so there is nothing to
    /// cancel and nothing that would return early.
    private func waitForTab() async {
        guard !enrichmentFinished else { return }
        let deadline = ContinuousClock.now + .seconds(1.5)
        // The sleep is `try?`, so without the cancellation check a cancelled task
        // would spin the main actor for the full 1.5s instead of sleeping.
        while !enrichmentFinished, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func write(_ text: String) throws {
        let now = Date()
        switch plan ?? .recordPoint(ActivityEvent(
            kind: .app, startedAt: now, endedAt: now, appName: resolved.appName
        )) {
        case .recordPoint(var event):
            event.note = text
            event.noteAt = now
            try model.store.recordActivity(event)

        case .annotateOpen(let open, let url, let title):
            try annotate(open, with: text, at: now, backfill: (url: url, title: title))

        case .beginSpan(let event):
            // Coalescing may hand back a span you noted earlier and have not
            // seen in this panel — `annotate` would replace those words.
            let target = try model.store.beginActivity(event)
            try annotate(target, with: text, at: now, backfill: (url: nil, title: nil))
        }
    }

    /// Writes `text` onto `target`, or beside it when that would overwrite words
    /// the panel never showed.
    ///
    /// The back-fill is applied here rather than by the caller because it must
    /// only touch a row this note actually lands on. Re-titling a row whose note
    /// we then diverted would attribute someone's existing sentence to whatever
    /// page happens to be in front now.
    private func annotate(
        _ target: ActivityEvent, with text: String, at now: Date,
        backfill: (url: String?, title: String?)
    ) throws {
        // Already said, nothing to do — accepting a suggestion sourced from this
        // very page arrives here. No back-fill either: the row already carries
        // this note, so re-labelling it runs the same risk.
        if target.note == text { return }

        guard CaptureTargeting.mayOverwrite(existing: target.note, shown: shownNote) else {
            // Words the panel never showed. Keep both: yours goes down beside
            // them rather than over them — and the row keeps its own title.
            try recordPoint(text, at: now)
            return
        }

        // Committed to writing on this row now, so it is safe to say what it is:
        // the span may have been opened before the tab could be read.
        if backfill.url != nil || backfill.title != nil {
            try model.store.describeActivity(
                id: target.id, target: backfill.title, url: backfill.url
            )
        }

        // A nil return means the row is no longer there to write on. The target
        // can be deleted from under us while this panel floats over the app —
        // Settings can forget a day, erase what was recorded automatically, or
        // delete everything, and ambient rows are pruned in the background. That
        // is not an error `annotate` throws for, so without this the panel would
        // confirm "Written down." over a note that went nowhere. A note is never
        // worth less than the row it was going to hang on.
        if try model.store.annotate(activityId: target.id, note: text) == nil {
            try recordPoint(text, at: now)
        }
    }

    /// Your words as an entry in their own right — the one place a rescue point
    /// is written, for when there is no row left to hang them on or none it
    /// would be safe to overwrite.
    private func recordPoint(_ text: String, at now: Date) throws {
        try model.store.recordActivity(ActivityEvent(
            kind: resolved.url != nil ? .browserTab : .app,
            startedAt: now, endedAt: now,
            appName: resolved.appName, bundleIdentifier: resolved.bundleIdentifier,
            target: resolved.pageTitle, url: resolved.url,
            note: text, noteAt: now
        ))
    }
}
