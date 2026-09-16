import SwiftUI
import AppKit
import FlowTraceCore

/// One memory in full: what you were looking at, what you wrote about it, and
/// what was happening on either side.
///
/// The design led with a screenshot. FlowTrace never takes one, so the hero is
/// the context we actually have — app, title, address, when and for how long.
struct MemoryDetailView: View {
    @Bindable var model: AppModel
    let eventId: String

    @State private var event: ActivityEvent?
    @State private var around: [ActivityEvent] = []
    @State private var loading = true
    /// A failed read. Without it this screen claims the memory is *gone*, which
    /// is a different and much worse thing to tell someone than "I couldn't
    /// read it".
    @State private var failure: String?
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingForget = false
    @FocusState private var noteFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Journal.Space.xl) {
                topBar
                if loading && event == nil {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Journal.Space.section)
                } else if let event {
                    columns(event)
                } else if let failure {
                    LoadFailureNotice(message: failure) { Task { await load() } }
                } else {
                    gone
                }
            }
            .frame(maxWidth: 1152, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, Journal.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(Journal.paper)
        .task(id: eventId) { await load() }
        .onChange(of: model.activityRevision) { Task { await load() } }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) { forget() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your note and the moment it was written on are removed from this Mac. This can't be undone.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Journal.Space.m) {
            Button {
                model.route = .memories
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left").font(.system(size: 11, weight: .semibold))
                    Text("Back to Memories").font(.observed(12.5, weight: .medium))
                }
                .foregroundStyle(Journal.inkMid)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Text("/").font(.observed(12)).foregroundStyle(Journal.ruleFirm)
            WashChip(MemoryFormat.shortId(eventId), mono: true)

            Spacer()

            if let event {
                if let url = event.url.flatMap(URL.init(string:)) {
                    WashButton(title: "Open", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                }
                WashButton(title: "Copy text", systemImage: "doc.on.doc") { copyNote(event) }
                WashButton(title: "View in Timeline", systemImage: "clock.arrow.circlepath") {
                    viewInTimeline(event)
                }
                WashButton(title: "Forget", systemImage: "trash", ink: Journal.danger) {
                    confirmingForget = true
                }
            }
        }
    }

    // MARK: - Layout

    private func columns(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: Journal.Space.xl) {
            VStack(alignment: .leading, spacing: Journal.Space.m) {
                contextCard(event)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.system(size: 10, weight: .semibold))
                    Text("Written down on this Mac. Never sent anywhere.")
                }
                .font(.caption())
                .foregroundStyle(Journal.inkSoft)
                .padding(.horizontal, Journal.Space.xs)
            }
            .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: Journal.Space.l) {
                lookingAt(event)
                personalNote(event)
                aroundThisMoment(event)
                rightFooter(event)
            }
            .frame(width: 400)
        }
    }

    // MARK: - The context card (left)

    private func contextCard(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Journal.Space.l) {
                HStack(spacing: Journal.Space.m) {
                    AppIconView(bundleIdentifier: event.bundleIdentifier, kind: event.kind, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.appName)
                            .font(.observed(13, weight: .medium))
                            .foregroundStyle(Journal.inkMid)
                        Text(event.kind.label)
                            .font(.caption())
                            .tracking(1.0)
                            .foregroundStyle(Journal.inkSoft)
                    }
                }

                Text(MemoryFormat.title(event))
                    .font(.journalTitle(22))
                    .tracking(-0.4)
                    .foregroundStyle(Journal.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let url = event.url, !url.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: MemoryFormat.kindCaption(event.kind))
                        Text(url)
                            .font(.mono(12, weight: .regular))
                            .foregroundStyle(Journal.pen)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                } else if let target = event.target, !target.isEmpty, target != MemoryFormat.title(event) {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: MemoryFormat.kindCaption(event.kind))
                        Text(target)
                            .font(.mono(12, weight: .regular))
                            .foregroundStyle(Journal.inkMid)
                            .textSelection(.enabled)
                    }
                }

                if event.kind == .agentSession, let asked = event.metadata["asked"], !asked.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: "what you asked")
                        Text(asked)
                            .font(.observed(12.5))
                            .foregroundStyle(Journal.inkMid)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(Journal.Space.xl)

            statusStrip(event)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.panel))
        .clipShape(RoundedRectangle(cornerRadius: Journal.Radius.panel))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    /// The design's mono status bar along the bottom of the hero: when, for how
    /// long, and where — as chips, because each is a separate fact.
    private func statusStrip(_ event: ActivityEvent) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Journal.Space.s) {
                Text(MemoryFormat.preciseClock(event.startedAt))
                    .font(.mono(12, weight: .semibold))
                    .foregroundStyle(Journal.ink)
                Text(event.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                    .font(.mono(11, weight: .regular))
                    .foregroundStyle(Journal.inkMid)
                if !event.durationLabel.isEmpty {
                    Text("·").foregroundStyle(Journal.ruleFirm)
                    Text(event.durationLabel)
                        .font(.mono(11, weight: .regular))
                        .foregroundStyle(Journal.inkMid)
                }
                Spacer(minLength: Journal.Space.m)
                if let place = event.metadata["place"], !place.isEmpty {
                    WashChip(place, fill: Journal.card, ink: Journal.inkMid) {
                        Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                    }
                }
                if let cwd = event.metadata["cwd"], !cwd.isEmpty {
                    Text(abbreviateHome(cwd))
                        .font(.mono(10.5, weight: .regular))
                        .foregroundStyle(Journal.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260)
                        .help(cwd)
                }
                if let windowTitle = event.metadata["windowTitle"], !windowTitle.isEmpty {
                    WashChip(windowTitle, fill: Journal.card, ink: Journal.inkMid) {
                        Image(systemName: "doc.text").font(.system(size: 10, weight: .semibold))
                    }
                }
                if event.kind != .agentSession, let messages = event.metadata["messages"], !messages.isEmpty {
                    WashChip("\(messages) message\(messages == "1" ? "" : "s")", mono: true, fill: Journal.card)
                }
            }
            .padding(.horizontal, Journal.Space.xl)
            .padding(.vertical, Journal.Space.m)
        }
        .background(Journal.paperDeep)
        .overlay(alignment: .top) { Divider().overlay(Journal.rule) }
    }

    // MARK: - Right column

    private func lookingAt(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack {
                Eyebrow(text: "What I was looking at")
                Spacer()
                WashChip("Primary focus", mono: true, fill: Journal.penSoft, ink: Journal.pen)
            }
            Text(MemoryFormat.title(event))
                .font(.observed(15, weight: .semibold))
                .foregroundStyle(Journal.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Journal.Space.s) {
                AppIconView(bundleIdentifier: event.bundleIdentifier, kind: event.kind, size: 16)
                Text("\(event.appName) · \(MemoryFormat.momentCaption(event.startedAt))")
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(1)
            }
            HStack(spacing: Journal.Space.s) {
                if let place = MemoryFormat.place(event) {
                    WashChip("Project: \(place)") {
                        Image(systemName: "folder").font(.system(size: 10, weight: .semibold))
                    }
                }
                WashChip(event.kind.label) {
                    Image(systemName: AppIconView.symbol(for: event.kind))
                        .font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(padding: Journal.Space.xl)
    }

    private func personalNote(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Journal.pen)
                    Eyebrow(text: "Personal note", ink: Journal.pen)
                }
                Spacer()
                if !editing {
                    Button {
                        beginEdit(event)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Journal.inkMid)
                            .frame(width: 24, height: 24)
                            .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
                    }
                    .buttonStyle(.plain)
                    .help("Edit note")
                }
            }

            if editing {
                VStack(alignment: .trailing, spacing: Journal.Space.s) {
                    TextField("why you were there", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.yourWords(16))
                        .foregroundStyle(Journal.ink)
                        .lineLimit(2...12)
                        .focused($noteFocused)
                        .onSubmit { saveEdit(event) }
                        .onExitCommand { cancelEdit() }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Journal.paper, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
                        .overlay(
                            RoundedRectangle(cornerRadius: Journal.Radius.field)
                                .strokeBorder(Journal.pen, lineWidth: 1)
                        )
                    HStack(spacing: Journal.Space.m) {
                        Text("Return saves · Esc cancels")
                            .font(.caption())
                            .foregroundStyle(Journal.inkSoft)
                        Spacer()
                        Button("Cancel") { cancelEdit() }
                            .buttonStyle(.plain)
                            .font(.observed(12, weight: .medium))
                            .foregroundStyle(Journal.inkMid)
                        Button("Save") { saveEdit(event) }
                            .buttonStyle(.plain)
                            .font(.observed(12, weight: .semibold))
                            .foregroundStyle(Journal.onPen)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Journal.pen, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
                    }
                }
            } else {
                Text("“\(event.note ?? "")”")
                    .font(.yourWords(16))
                    .foregroundStyle(Journal.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let noteAt = event.noteAt {
                    Text("Written at \(MemoryFormat.clock(noteAt))")
                        .font(.caption())
                        .foregroundStyle(Journal.inkSoft)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(padding: Journal.Space.xl)
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card)
                .strokeBorder(Journal.penSoft, lineWidth: 1)
        )
    }

    // MARK: Around this moment

    /// The eight rows nearest in time to the memory, in time order, with the
    /// memory itself placed among them.
    private func neighbours(of event: ActivityEvent) -> [ActivityEvent] {
        let others = around
            .filter { $0.id != event.id }
            .sorted { abs($0.startedAt.timeIntervalSince(event.startedAt)) < abs($1.startedAt.timeIntervalSince(event.startedAt)) }
            .prefix(8)
        return (Array(others) + [event]).sorted { $0.startedAt < $1.startedAt }
    }

    private func aroundThisMoment(_ event: ActivityEvent) -> some View {
        let rows = neighbours(of: event)
        return VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack {
                Eyebrow(text: "Around this moment")
                Spacer()
                WashChip("Timeline", mono: true)
            }
            if rows.count == 1 {
                Text("Nothing else recorded around then.")
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                    .padding(.vertical, Journal.Space.xs)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        neighbourRow(row, anchor: event)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(padding: Journal.Space.xl)
    }

    private func neighbourRow(_ row: ActivityEvent, anchor: ActivityEvent) -> some View {
        let isThis = row.id == anchor.id
        return HStack(alignment: .top, spacing: Journal.Space.s) {
            AppIconView(bundleIdentifier: row.bundleIdentifier, kind: row.kind, size: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(MemoryFormat.clock(row.startedAt))
                        .font(.mono(11))
                        .foregroundStyle(isThis ? Journal.pen : Journal.ink)
                    Text(isThis ? "(this memory)" : MemoryFormat.offsetCaption(row.startedAt, from: anchor.startedAt))
                        .font(.caption())
                        .foregroundStyle(isThis ? Journal.pen : Journal.inkSoft)
                    Text("· \(row.appName)")
                        .font(.observed(11))
                        .foregroundStyle(Journal.inkSoft)
                        .lineLimit(1)
                }
                Text(MemoryFormat.title(row))
                    .font(.observed(12.5, weight: isThis ? .semibold : .regular))
                    .foregroundStyle(isThis ? Journal.ink : Journal.inkMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Journal.Space.s)
        .padding(.vertical, 6)
        .background(
            isThis ? Journal.penSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: Journal.Radius.field)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isThis, !row.isUnexplained { model.route = .memory(row.id) }
        }
        .help(isThis ? "" : (row.isUnexplained ? MemoryFormat.title(row) : "Show this memory"))
    }

    // MARK: Footer

    private func rightFooter(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.l) {
            VStack(alignment: .leading, spacing: Journal.Space.s) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).padding(.top, 1)
                    Text("Recorded by FlowTrace while you worked.")
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "internaldrive").font(.system(size: 10, weight: .semibold)).padding(.top, 1)
                    Text("Stored locally in flowtrace.sqlite.")
                }
            }
            .font(.caption())
            .foregroundStyle(Journal.inkSoft)
            .padding(.horizontal, Journal.Space.xs)

            HStack(spacing: Journal.Space.m) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Journal.inkMid)
                Text("Jump into the chronological stream")
                    .font(.observed(12.5, weight: .medium))
                    .foregroundStyle(Journal.ink)
                    .lineLimit(2)
                Spacer(minLength: Journal.Space.s)
                Button {
                    viewInTimeline(event)
                } label: {
                    Text("View in Timeline")
                        .font(.observed(12, weight: .semibold))
                        .foregroundStyle(Journal.onPen)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Journal.pen, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
                }
                .buttonStyle(.plain)
            }
            .padding(Journal.Space.l)
            .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Journal.Radius.card)
                    .strokeBorder(Journal.rule, lineWidth: 1)
            )
        }
    }

    // MARK: - Gone

    private var gone: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            Text("That memory is gone.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)
            Text("It was forgotten, or the row it was written on no longer exists.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
            Button {
                model.route = .memories
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left").font(.system(size: 11, weight: .semibold))
                    Text("Back to Memories").font(.observed(12.5, weight: .semibold))
                }
                .foregroundStyle(Journal.onPen)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Journal.pen, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
            }
            .buttonStyle(.plain)
            .padding(.top, Journal.Space.xs)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .memoryCard(padding: Journal.Space.xl)
    }

    // MARK: - Actions

    private func copyNote(_ event: ActivityEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.note ?? "", forType: .string)
        model.toast = Toast(message: "Copied")
    }

    private func viewInTimeline(_ event: ActivityEvent) {
        model.timelineFocus = (day: event.startedAt, eventId: event.id)
        model.route = .timeline
    }

    private func beginEdit(_ event: ActivityEvent) {
        draft = event.note ?? ""
        editing = true
        noteFocused = true
    }

    private func cancelEdit() {
        editing = false
        draft = ""
    }

    /// Return saves. An emptied field cancels rather than clearing: a memory
    /// with no note stops being a memory, and Forget is the labelled way there.
    private func saveEdit(_ event: ActivityEvent) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelEdit(); return }
        do {
            guard let saved = try model.store.annotate(activityId: event.id, note: text) else {
                model.toast = Toast(message: "That memory is gone", isError: true)
                model.route = .memories
                return
            }
            self.event = saved
            cancelEdit()
            model.toast = Toast(message: "Saved")
            model.activityRevision += 1
        } catch {
            model.toast = Toast(message: "Couldn't save the note: \(error.localizedDescription)", isError: true)
        }
    }

    private func forget() {
        do {
            try model.store.deleteActivity(id: eventId)
            model.toast = Toast(message: "Forgotten")
            model.route = .memories
            model.activityRevision += 1
        } catch {
            model.toast = Toast(message: "Couldn't forget that: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Data

    private func load() async {
        let store = model.store
        let id = eventId
        let read = await Task.detached(priority: .userInitiated) {
            () -> Result<(ActivityEvent?, [ActivityEvent]), Error> in
            do {
                guard let found = try store.activity(id: id) else { return .success((nil, [])) }
                let nearby = try store.activity(around: found.startedAt, within: 45)
                return .success((found, nearby))
            } catch {
                return .failure(error)
            }
        }.value

        switch read {
        case .success(let (found, nearby)):
            event = found
            around = nearby
            failure = nil
        case .failure(let error):
            failure = error.localizedDescription
        }
        loading = false
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
