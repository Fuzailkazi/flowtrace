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
    /// What the tab continuation last computed, so a later suggestion refresh
    /// can pass the same value rather than dropping it.
    @State private var tabNote: String?
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
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            contextCard
            if saved { confirmation } else { noteArea }
            footerBar
        }
        .frame(width: QuickCapturePanel.width, alignment: .leading)
        .background(Journal.paper)
        .clipShape(RoundedRectangle(cornerRadius: Journal.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.panel, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .onAppear(perform: load)
        // The one measurement that settles whether keystrokes are being lost:
        // how much text actually reached the field, and whether it was kept.
        // A run of "0 chars" closes on apps where you know you typed is the
        // evidence for a focus problem; anything else is not.
        .onDisappear {
            Diagnostics.log(
                "capture closed over \(resolved.appName) — "
                + "\(note.count) chars reached the field, saved: \(saved)"
            )
        }
    }

    // MARK: - Title bar

    /// The design's window title bar: mark, name, the key, and where you were.
    private var titleBar: some View {
        HStack(spacing: Journal.Space.m) {
            HStack(spacing: 6) {
                BrandMarkView(size: 16, color: Journal.ink)
                Text("Quick Capture")
                    .font(.observed(12, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Journal.ink)
                keycap(model.captureTrigger.displayString)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(Journal.live).frame(width: 7, height: 7)
                Text("Where you were, just now")
                    .font(.observed(11, weight: .medium))
                    .foregroundStyle(Journal.inkMid)
            }
            appChip(resolved.appName)

            // Escape works, but a panel with no visible way out reads as a
            // thing that has taken over rather than one you summoned.
            Button(action: { if !saving { onFinish() } }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Journal.inkSoft)
                    .padding(5)
                    .background(Journal.wash, in: Circle())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close without writing anything (esc)")
        }
        .padding(.horizontal, Journal.Space.l)
        .frame(height: 44)
        .background(
            LinearGradient(colors: [Journal.card, Journal.paperDeep], startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .bottom) { Divider().overlay(Color.black.opacity(0.06)) }
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.mono(10))
            .foregroundStyle(Journal.inkSoft)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
    }

    private func appChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            if let icon = appIcon {
                Image(nsImage: icon).resizable().frame(width: 12, height: 12)
            }
            Text(name).font(.observed(11, weight: .medium))
        }
        .foregroundStyle(Journal.inkMid)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.black.opacity(0.04), in: Capsule())
    }

    /// What the panel can say when the app gave up nothing but its name. The
    /// window title needs Accessibility; a page needs Automation for that
    /// browser. Naming the missing permission beats an empty card.
    private var knownOnlyByApp: String {
        if resolved.automationDenied {
            return "FlowTrace can't read \(resolved.appName)'s tabs, so the note lands on the app."
        }
        if resolved.isBrowser {
            return "Reading the tab…"
        }
        if !AccessibilityPermission.isGranted {
            return "No window title — grant Accessibility in Settings and entries say which window."
        }
        return "No window title. The note lands on \(resolved.appName)."
    }

    /// The frontmost app's real icon, when macOS knows it.
    private var appIcon: NSImage? {
        guard let id = resolved.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Where you are

    /// The design shows a captured frame here. FlowTrace takes no screenshots,
    /// so the slot holds what it actually knows about where you are: the page
    /// or window, the address, the project — on the same dark card.
    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Journal.pen).frame(width: 7, height: 7)
                    Text(resolved.place?.name ?? resolved.summary)
                        .font(.mono(11.5, weight: .semibold))
                        .foregroundStyle(Color(white: 0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = resolved.detail {
                        Text("— \(detail)")
                            .font(.mono(10.5))
                            .foregroundStyle(Color(white: 0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(Date(), format: .dateTime.hour().minute().second())
                        .font(.mono(10))
                        .foregroundStyle(Color(white: 0.55))
                }
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Divider().overlay(Color(white: 0.2)) }

                VStack(alignment: .leading, spacing: 6) {
                    if resolved.summary != resolved.appName {
                        Text(resolved.summary)
                            .font(.journalTitle(17))
                            .tracking(-0.3)
                            .foregroundStyle(Color(white: 0.95))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        // All FlowTrace knows is which app was in front. Say that,
                        // rather than printing its name a third time.
                        Text(knownOnlyByApp)
                            .font(.observed(12))
                            .foregroundStyle(Color(white: 0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = resolved.url {
                        Text(url)
                            .font(.mono(11))
                            .foregroundStyle(Color(white: 0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let place = resolved.place {
                        Text(place.root.abbreviatingHome)
                            .font(.mono(11))
                            .foregroundStyle(Color(white: 0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let title = resolved.windowTitle, title != resolved.summary {
                        Text(title)
                            .font(.mono(11))
                            .foregroundStyle(Color(white: 0.6))
                            .lineLimit(1)
                    }
                    if resolved.openTabCount > 1 {
                        Text("\(resolved.openTabCount) tabs open in this window")
                            .font(.mono(10.5))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    if let current, current.isOpen, isAnnotatingOpenSpan {
                        Text("here for \(current.durationLabel)")
                            .font(.mono(10.5))
                            .foregroundStyle(Color(white: 0.5))
                    }
                }
                .padding(.top, 10)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)

            // Keep the destination visible without repeating the app identity
            // already established in the panel title bar and context header.
            HStack(spacing: 8) {
                if let place = resolved.place {
                    Circle().fill(Journal.pen).frame(width: 6, height: 6)
                    Text(place.name)
                        .font(.mono(10.5))
                        .foregroundStyle(Color.white.opacity(0.8))
                } else {
                    Text("Saved to \\(resolved.appName)")
                        .font(.observed(11, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
                if resolved.automationDenied {
                    Button("Allow reading tabs…") { AutomationPermission.openSettings() }
                        .buttonStyle(.plain)
                        .font(.mono(10.5))
                        .foregroundStyle(Journal.amber)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
        .background(Color(nsColor: NSColor(hex: "0F1117")))
        .clipShape(RoundedRectangle(cornerRadius: Journal.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card, style: .continuous)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
        )
        .padding(14)
        .background(Journal.paperDeep)
        .overlay(alignment: .bottom) { Divider().overlay(Color.black.opacity(0.05)) }
    }

    // MARK: - The one field

    /// The placeholder names where you are, so the blank field never reads as
    /// a blank box: "why are you on XYZ video?" beats "why are you here?".
    private var placeholder: String {
        let where_ = resolved.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if where_.isEmpty || where_ == resolved.appName { return "why are you here?" }
        let short = where_.count > 60 ? String(where_.prefix(60)) + "…" : where_
        return "why are you on \(short)?"
    }

    private var noteArea: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack {
                HStack(spacing: 5) {
                    Text("Why are you here?")
                        .font(.observed(12, weight: .medium))
                        .foregroundStyle(Journal.inkMid)
                    Text("— your words, kept")
                        .font(.observed(12))
                        .foregroundStyle(Journal.inkSoft)
                }
                Spacer()
                Text("Press ⏎ to save")
                    .font(.mono(10.5))
                    .foregroundStyle(Journal.inkSoft)
            }

            TextField(placeholder, text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(.yourWords(14.5))
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
                .padding(12)
                .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Journal.Radius.card)
                        .strokeBorder(focused ? Journal.pen : Color.black.opacity(0.08), lineWidth: 1)
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
                .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
            }
        }
        .padding(Journal.Space.l)
        .background(Journal.card)
        .background {
            Button("") { if !saving { onFinish() } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    private var confirmation: some View {
        HStack(spacing: Journal.Space.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Journal.pen)
            Text("Written down.").font(.observed(13, weight: .medium)).foregroundStyle(Journal.ink)
            Spacer()
        }
        .padding(Journal.Space.l)
        .background(Journal.card)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: Journal.Space.s) {
            // Where the note will be filed, as the design's project chip.
            HStack(spacing: 6) {
                Circle().fill(Journal.pen).frame(width: 7, height: 7)
                if let place = resolved.place {
                    Text("Project: \(place.name)")
                } else {
                    Text(resolved.appName)
                }
            }
            .font(.observed(11.5))
            .foregroundStyle(Journal.inkMid)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Journal.Radius.field).strokeBorder(Color.black.opacity(0.08), lineWidth: 1))

            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 10))
                Text("Stays on this Mac")
            }
            .font(.observed(11))
            .foregroundStyle(Journal.inkSoft)

            Spacer()

            Button(action: { if !saving { onFinish() } }) {
                HStack(spacing: 5) {
                    Text("Discard").font(.observed(12, weight: .medium)).foregroundStyle(Journal.inkMid)
                    keycap("Esc")
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: save) {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill").font(.system(size: 11, weight: .semibold))
                    Text("Remember this").font(.observed(12.5, weight: .semibold))
                    Text("↵")
                        .font(.mono(10.5, weight: .regular))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                }
                .foregroundStyle(Journal.onPen)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Journal.pen, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
                .shadow(color: Journal.pen.opacity(0.25), radius: 6, y: 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saving || saved)
        }
        .padding(.horizontal, Journal.Space.l)
        .padding(.vertical, Journal.Space.m)
        .background(Journal.paper)
        .overlay(alignment: .top) { Divider().overlay(Color.black.opacity(0.06)) }
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

    private func suggestionSourceLabel(_ suggestion: CaptureSuggestion) -> String {
        switch suggestion.source {
        case .projectNote: "Your project note"
        case .tabNote: "Your note on this page"
        case .agentPrompt: "You asked"
        }
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if canAcceptSuggestion, let suggestion {
            HStack(spacing: 6) {
                Text("SUGGESTED · \(suggestionSourceLabel(suggestion).uppercased())")
                    .font(.caption(10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(Journal.inkSoft)
                Button(action: acceptSuggestion) {
                    HStack(spacing: 4) {
                        Text("+").font(.observed(11.5, weight: .medium)).foregroundStyle(Journal.pen)
                        Text(suggestion.text)
                            .font(.observed(11.5))
                            .foregroundStyle(Journal.ink)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
                    .overlay(RoundedRectangle(cornerRadius: Journal.Radius.field).strokeBorder(Color.black.opacity(0.05), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Press Tab to fill the field with this, then Return to save")
                Spacer()
                Text("Tab to use")
                    .font(.mono(10))
                    .foregroundStyle(Journal.inkSoft)
            }
        }
    }

    /// The currently-open activity's project, or — scanning newest-first — the
    /// first `leadingUp` event that has one. Stops at the first `cwd` found,
    /// whether or not a `ProjectNote` exists for it: this is a single best guess,
    /// not a search across every project mentioned in the last 20 minutes.
    private func projectNoteCandidate() -> String? {
        // The editor's answer for right now beats a cwd left on a row by an
        // earlier capture in another project. The open VS Code span outlives
        // the project it was noted in, so without this the top-priority
        // suggestion would be an hour-old project's "what am I building".
        let cwd = resolved.place?.root
            ?? current?.metadata["cwd"]
            ?? leadingUp.compactMap { $0.metadata["cwd"] }.first
        guard let cwd, !cwd.isEmpty else { return nil }
        do {
            return try model.store.projectNote(for: cwd)?.building
        } catch {
            Diagnostics.log("capture: reading the project note failed: \(error)")
            return nil
        }
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
        // A failed read here costs context, not the note: the plan falls back to
        // opening a fresh span and the save path is unaffected. Logged rather
        // than surfaced, because a panel that opens with a database error over
        // it is worse than one that opens with less to say.
        do {
            current = try model.store.openActivity()
            leadingUp = try model.store.activityLeadingUp(to: Date())
        } catch {
            Diagnostics.log("capture: reading context failed: \(error)")
            current = nil
            leadingUp = []
        }
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
                // Two tasks own `resolved`: this one assigns whole snapshots
                // built from a pre-place local, so it must carry over whatever
                // the place task has already landed. Today `resolvingActiveTab`
                // returns `self` for a non-browser and the equality guard skips
                // the assignment — so the place would survive by accident, and
                // a later change to that function would silently delete it.
                if identified != snapshot {
                    var next = identified
                    next.place = resolved.place
                    next.placeChecked = resolved.placeChecked
                    resolved = next
                }
                refreshPlan()
                if note.isEmpty, let prefill = CaptureTargeting.prefill(
                    open: current, site: resolved.site, recording: model.recorder.isRunning
                ) {
                    note = prefill
                    shownNote = prefill
                }
                if let url = identified.url {
                    do {
                        tabNote = try model.store.noteForTab(url: url)
                    } catch {
                        Diagnostics.log("capture: reading this page's note failed: \(error)")
                        tabNote = nil
                    }
                    recomputeSuggestion(tabNote: tabNote)
                }
                // Everything the note's destination depends on is now known.
                enrichmentFinished = true
            }

            let counted = identified.resolvingTabCount()
            await MainActor.run {
                if counted != identified {
                    var next = counted
                    next.place = resolved.place
                    next.placeChecked = resolved.placeChecked
                    resolved = next
                }
            }
        }

        // Only an editor is asked, and only ever about its own state file.
        guard let family = EditorFamily.matching(bundleIdentifier: snapshot.bundleIdentifier)
        else { return }

        // The file is written when a window loses focus — and activating this
        // panel is what blurs it. That write is throttled ~100ms, so reading
        // immediately returns the window we *left*, which for a switch
        // between two editor windows is the sibling project: the worst answer
        // this feature could give. So wait for our own blur to land.
        //
        // Its own task, deliberately: the tab task above flips
        // `enrichmentFinished`, and waiting here before that flip would put
        // every non-browser capture behind the 1.5s bound in `save()`, which
        // today it never touches.
        let openedAt = Date()
        Task.detached(priority: .userInitiated) {
            let url = EditorPlace.storageURL(for: family, support: EditorPlace.defaultSupport)
            let deadline = ContinuousClock.now + .milliseconds(400)
            while ContinuousClock.now < deadline {
                let written = (try? FileManager.default.attributesOfItem(atPath: url.path))
                    .flatMap { $0[.modificationDate] as? Date }
                if let written, written >= openedAt { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let place = EditorPlace.place(forBundleIdentifier: snapshot.bundleIdentifier)
            await MainActor.run {
                // Only these two fields — the whole snapshot belongs to the tab
                // task. `placeChecked` is set unconditionally and in the same
                // turn as `place`, so a genuine nil answer is recorded as
                // *asked*: that is what entitles the write to clear a stale
                // place, and what stops a fast Return from clearing one before
                // this task has had a chance to look.
                resolved.place = place
                resolved.placeChecked = true
                refreshPlan()
                recomputeSuggestion(tabNote: tabNote)
            }
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
            // The recorder writes spans off the main thread now. If the key was
            // pressed moments after switching apps, its span for where you are
            // may still be in flight — planning against the database before it
            // lands would file the note on the app you just left.
            await model.recorder.settled()

            do {
                // The load-time span can be seconds stale, and which tab you are
                // on may only just have arrived.
                current = try model.store.openActivity()
                refreshPlan()
                try write(text)

                model.activityRevision &+= 1
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
        // The default is unreachable — `load()` always sets `plan`, and `save()`
        // rebuilds it — so it needs no place: there is no row for one to land on
        // that this fallback would be the one to describe.
        switch plan ?? .recordPoint(ActivityEvent(
            kind: .app, startedAt: now, endedAt: now, appName: resolved.appName
        )) {
        case .recordPoint(var event):
            // The place is already in this event: `plan` built it from the site.
            event.note = text
            event.noteAt = now
            try model.store.recordActivity(event)

        case .annotateOpen(let open, let url, let title, let place):
            try annotate(
                open, with: text, at: now, backfill: (url: url, title: title, windowTitle: resolved.windowTitle), place: place
            )

        case .beginSpan(let event):
            // Coalescing may hand back a span you noted earlier and have not
            // seen in this panel — `annotate` would replace those words.
            //
            // And the place must be applied to the row this returns, not merely
            // built into the event: `beginActivity` discards the passed event on
            // two paths — the coalesce, and the five-minute resume — so an
            // alt-tab to Slack and back would throw a freshly resolved place away.
            let target = try model.store.beginActivity(event)
            try annotate(
                target, with: text, at: now, backfill: (url: nil, title: nil, windowTitle: resolved.windowTitle),
                place: resolved.site.placeBackfill
            )
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
        backfill: (url: String?, title: String?, windowTitle: String?), place: PlaceBackfill
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
        if let title = backfill.windowTitle, !title.isEmpty {
            try model.store.describeActivity(id: target.id, metadata: ["windowTitle": title])
        }

        // Same path and same rule: the place is only ever said about a row this
        // note is actually landing on. `.clear` is not "nothing to say" — it is
        // an editor that gave no answer, and leaving an earlier capture's
        // project on the row would file this sentence under the wrong one.
        switch place {
        case .unchanged: break
        case .set(let name, let root):
            try model.store.describeActivity(id: target.id, metadata: ["place": name, "cwd": root])
        case .clear:
            try model.store.describeActivity(id: target.id, metadata: ["place": nil, "cwd": nil])
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
            note: text, noteAt: now,
            // Mirrors "site as event": a diverted note keeps its place, or the
            // rescue point is the one row that cannot say where it was written.
            // Read off the site, which is the single mapping from a `Place` to
            // these two keys. `tabsOpen` is a browser concern and this is not
            // one of those paths.
            metadata: {
                let site = resolved.site
                var metadata: [String: String] = [:]
                if let name = site.placeName { metadata["place"] = name }
                if let root = site.placeRoot { metadata["cwd"] = root }
                if let title = site.windowTitle, !title.isEmpty { metadata["windowTitle"] = title }
                return metadata
            }()
        ))
    }
}
