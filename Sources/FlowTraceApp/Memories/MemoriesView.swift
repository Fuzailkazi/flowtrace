import SwiftUI
import AppKit
import FlowTraceCore

/// Everything you wrote down, across days.
///
/// A memory is an activity row with a note on it — nothing more. There are no
/// screenshots and no index behind this screen: it loads the noted rows once
/// and filters them in memory as you type.
struct MemoriesView: View {
    @Bindable var model: AppModel

    @State private var memories: [ActivityEvent] = []
    @State private var projects: [ProjectNote] = []
    @State private var loading = true
    /// A failed load. A toast says it once and goes; this screen is the record
    /// of everything you wrote, so an unreadable one has to keep saying so
    /// rather than looking like you never wrote anything.
    @State private var failure: String?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var layout: Layout = .grid
    @State private var hovering: String?
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var editFocused: Bool

    enum Filter: Hashable {
        case all, today, yesterday, week, withPlace
        case app(String)
    }

    enum Layout { case grid, list }

    private static let columns = [GridItem(.adaptive(minimum: 300, maximum: 520), spacing: Journal.Space.xl)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Journal.Space.xxl) {
                header
                if let failure {
                    LoadFailureNotice(message: failure) { Task { await load() } }
                }
                searchField
                filterChips
                stream
                if !projects.isEmpty { building }
                footer
            }
            .frame(maxWidth: 1152, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, Journal.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(Journal.paper)
        .background {
            // ⌘F: an invisible button so the shortcut lives with the screen and
            // not in the menu bar.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task { await load() }
        .onChange(of: model.activityRevision) { Task { await load() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Journal.Space.l) {
            VStack(alignment: .leading, spacing: Journal.Space.s) {
                Eyebrow(text: "What you wrote down", ink: Journal.pen)
                Text("What do you remember?")
                    .font(.journalTitle(30))
                    .tracking(-0.4)
                    .foregroundStyle(Journal.ink)
                Text("Everything you wrote down, across days. Kept on this Mac.")
                    .font(.observed(13.5))
                    .foregroundStyle(Journal.inkMid)
            }
            Spacer(minLength: Journal.Space.l)
            HStack(spacing: Journal.Space.m) {
                Label("\(memories.count) memor\(memories.count == 1 ? "y" : "ies")", systemImage: "note.text")
                Text("·").foregroundStyle(Journal.ruleFirm)
                Label("on this Mac", systemImage: "internaldrive")
            }
            .font(.caption())
            .foregroundStyle(Journal.inkMid)
            .padding(.horizontal, Journal.Space.m)
            .padding(.vertical, Journal.Space.s)
            .background(Journal.wash, in: Capsule())
            .padding(.top, Journal.Space.xl)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: Journal.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Journal.inkSoft)
            TextField(
                "Search your memories… e.g. 'pricing', 'HUD level'",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.observed(14))
            .foregroundStyle(Journal.ink)
            .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Journal.inkSoft)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
            Text("⌘F")
                .font(.caption())
                .foregroundStyle(Journal.inkSoft)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
        }
        .padding(.horizontal, Journal.Space.l)
        .padding(.vertical, Journal.Space.m)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card)
                .strokeBorder(searchFocused ? Journal.pen : Journal.rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    // MARK: - Filters

    /// One chip per app in the loaded rows, most-used first. The icon comes from
    /// the first row that carried a bundle id.
    private var apps: [(name: String, bundle: String?)] {
        var counts: [String: Int] = [:]
        var bundles: [String: String] = [:]
        for event in memories {
            counts[event.appName, default: 0] += 1
            if bundles[event.appName] == nil, let bundle = event.bundleIdentifier { bundles[event.appName] = bundle }
        }
        return counts.keys
            .sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
            .map { ($0, bundles[$0]) }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Journal.Space.s) {
                filterChip("All", .all)
                filterChip("Today", .today)
                filterChip("Yesterday", .yesterday)
                filterChip("Last 7 days", .week)
                filterChip("With a place", .withPlace, systemImage: "folder")
                if !apps.isEmpty {
                    Rectangle().fill(Journal.ruleFirm).frame(width: 1, height: 16)
                        .padding(.horizontal, Journal.Space.xs)
                }
                ForEach(apps, id: \.name) { app in
                    filterChip(app.name, .app(app.name)) {
                        AppIconView(bundleIdentifier: app.bundle, kind: .app, size: 14)
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, _ value: Filter, systemImage: String? = nil) -> some View {
        filterChip(title, value) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
        }
    }

    private func filterChip<Leading: View>(
        _ title: String, _ value: Filter, @ViewBuilder leading: @escaping () -> Leading
    ) -> some View {
        let selected = filter == value
        return Button {
            filter = value
        } label: {
            WashChip(
                title,
                fill: selected ? Journal.ink : Journal.wash,
                ink: selected ? Journal.paper : Journal.inkMid,
                leading: leading
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stream

    private var visible: [ActivityEvent] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        let now = Date()
        return memories.filter { event in
            let passesFilter: Bool = switch filter {
            case .all: true
            case .today: calendar.isDate(event.startedAt, inSameDayAs: now)
            case .yesterday:
                calendar.date(byAdding: .day, value: -1, to: now)
                    .map { calendar.isDate(event.startedAt, inSameDayAs: $0) } ?? false
            case .week:
                calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
                    .map { event.startedAt >= $0 } ?? true
            case .withPlace: MemoryFormat.hasPlace(event)
            case .app(let name): event.appName == name
            }
            guard passesFilter else { return false }
            guard !needle.isEmpty else { return true }
            return [event.note, event.target, event.url, event.appName, event.metadata["place"], event.metadata["cwd"]]
                .contains { ($0 ?? "").localizedCaseInsensitiveContains(needle) }
        }
    }

    private var stream: some View {
        VStack(alignment: .leading, spacing: Journal.Space.l) {
            HStack(spacing: Journal.Space.m) {
                Text("Memory Stream")
                    .font(.journalTitle(17))
                    .foregroundStyle(Journal.ink)
                WashChip("Newest first", mono: true)
                Spacer()
                HStack(spacing: 2) {
                    layoutToggle(.grid, systemImage: "square.grid.2x2", help: "Grid")
                    layoutToggle(.list, systemImage: "list.bullet", help: "List")
                }
            }

            if loading && memories.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Journal.Space.section)
            } else if memories.isEmpty {
                // Silent when the notice above is already explaining why this
                // is empty — "nothing remembered yet" would be a second, wrong
                // answer to the same question.
                if failure == nil { nothingYet }
            } else if visible.isEmpty {
                Text("No memories match.")
                    .font(.observed(13))
                    .foregroundStyle(Journal.inkSoft)
                    .padding(.vertical, Journal.Space.xl)
            } else if layout == .grid {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Journal.Space.xl) {
                    ForEach(visible) { event in card(event) }
                }
            } else {
                LazyVStack(spacing: Journal.Space.s) {
                    ForEach(visible) { event in row(event) }
                }
            }
        }
    }

    private func layoutToggle(_ value: Layout, systemImage: String, help: String) -> some View {
        Button {
            layout = value
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(layout == value ? Journal.ink : Journal.inkSoft)
                .frame(width: 26, height: 26)
                .background(
                    layout == value ? Journal.rule : Color.clear,
                    in: RoundedRectangle(cornerRadius: Journal.Radius.chip)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var nothingYet: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            Text("Nothing remembered yet.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)
            Text("Press \(model.captureTrigger.displayString) anywhere and write why you're there. It lands here.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(padding: Journal.Space.xl)
    }

    // MARK: - One memory, as a card

    private func appChip(_ event: ActivityEvent) -> some View {
        WashChip(event.appName) {
            AppIconView(bundleIdentifier: event.bundleIdentifier, kind: event.kind, size: 18)
        }
    }

    private func card(_ event: ActivityEvent) -> some View {
        let isHovered = hovering == event.id
        return VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack(alignment: .center) {
                appChip(event)
                Spacer(minLength: Journal.Space.s)
                Text(MemoryFormat.dayCaption(event.startedAt))
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)
            }

            Text(MemoryFormat.title(event))
                .font(.observed(14, weight: .semibold))
                .foregroundStyle(Journal.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            noteBlock(event, lines: 4)

            HStack(spacing: Journal.Space.s) {
                if let footer = MemoryFormat.footer(event) {
                    Text(footer)
                        .font(.mono(11))
                        .foregroundStyle(Journal.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if isHovered && editing != event.id { actions(event) }
            }
            .frame(minHeight: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard()
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card)
                .strokeBorder(isHovered ? Journal.ruleFirm : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 ? event.id : (hovering == event.id ? nil : hovering) }
        .onTapGesture { open(event) }
        .contextMenu { menu(event) }
    }

    /// The same memory as one line, for the list layout.
    private func row(_ event: ActivityEvent) -> some View {
        let isHovered = hovering == event.id
        return HStack(alignment: .center, spacing: Journal.Space.m) {
            AppIconView(bundleIdentifier: event.bundleIdentifier, kind: event.kind, size: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Journal.Space.s) {
                    Text(MemoryFormat.title(event))
                        .font(.observed(13.5, weight: .semibold))
                        .foregroundStyle(Journal.ink)
                        .lineLimit(1)
                    if let footer = MemoryFormat.footer(event) {
                        Text(footer)
                            .font(.mono(10.5))
                            .foregroundStyle(Journal.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                noteBlock(event, lines: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered && editing != event.id { actions(event) }

            VStack(alignment: .trailing, spacing: 3) {
                Text(MemoryFormat.dayCaption(event.startedAt))
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                Text(event.appName)
                    .font(.observed(11))
                    .foregroundStyle(Journal.inkSoft)
            }
            .lineLimit(1)
            .frame(minWidth: 96, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard(padding: Journal.Space.m)
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card)
                .strokeBorder(isHovered ? Journal.ruleFirm : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 ? event.id : (hovering == event.id ? nil : hovering) }
        .onTapGesture { open(event) }
        .contextMenu { menu(event) }
    }

    /// Your words, as a quote — or the field to change them.
    @ViewBuilder
    private func noteBlock(_ event: ActivityEvent, lines: Int) -> some View {
        if editing == event.id {
            HStack(alignment: .top, spacing: Journal.Space.s) {
                TextField("why you were there", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.yourWords(14))
                    .foregroundStyle(Journal.ink)
                    .lineLimit(1...6)
                    .focused($editFocused)
                    .onSubmit { saveEdit(event) }
                    .onExitCommand { cancelEdit() }
                Button("Save") { saveEdit(event) }
                    .buttonStyle(.plain)
                    .font(.observed(11, weight: .medium))
                    .foregroundStyle(Journal.pen)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Journal.paper, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
            .overlay(RoundedRectangle(cornerRadius: Journal.Radius.field).strokeBorder(Journal.pen, lineWidth: 1))
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Journal.inkSoft)
                    .padding(.top, 3)
                Text(event.note ?? "")
                    .font(.yourWords(14))
                    .foregroundStyle(Journal.ink)
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actions(_ event: ActivityEvent) -> some View {
        HStack(spacing: 4) {
            if let url = event.url.flatMap(URL.init(string:)) {
                IconButton(systemImage: "arrow.up.right.square", help: "Open") {
                    NSWorkspace.shared.open(url)
                }
            }
            IconButton(systemImage: "pencil", help: "Edit note") { beginEdit(event) }
            IconButton(systemImage: "trash", help: "Forget", ink: Journal.danger) { forget(event) }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func menu(_ event: ActivityEvent) -> some View {
        Button("Show memory") { open(event) }
        if let url = event.url.flatMap(URL.init(string:)) {
            Button("Open") { NSWorkspace.shared.open(url) }
        }
        Button("Edit note") { beginEdit(event) }
        Button("Copy note") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(event.note ?? "", forType: .string)
            model.toast = Toast(message: "Copied")
        }
        Divider()
        Button("Forget", role: .destructive) { forget(event) }
    }

    // MARK: - What you're building

    private var building: some View {
        VStack(alignment: .leading, spacing: Journal.Space.l) {
            HStack(spacing: Journal.Space.m) {
                Text("What you're building")
                    .font(.journalTitle(17))
                    .foregroundStyle(Journal.ink)
                WashChip("\(projects.count) place\(projects.count == 1 ? "" : "s")", mono: true)
            }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Journal.Space.xl) {
                ForEach(projects) { note in projectCard(note) }
            }
        }
    }

    private func projectCard(_ note: ProjectNote) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Journal.inkSoft)
                    Text(note.repositoryName)
                        .font(.observed(14, weight: .semibold))
                        .foregroundStyle(Journal.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: Journal.Space.s)
                Text(MemoryFormat.dayCaption(note.updatedAt))
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)
            }
            if !note.building.isEmpty {
                Text("“\(note.building)”")
                    .font(.yourWords(14))
                    .foregroundStyle(Journal.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !note.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Next")
                        .font(.caption())
                        .tracking(1.0)
                        .foregroundStyle(Journal.inkSoft)
                        .padding(.top, 2)
                    Text(note.nextStep)
                        .font(.observed(13))
                        .foregroundStyle(Journal.inkMid)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if note.isPaused {
                WashChip("Paused", mono: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .memoryCard()
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: note.repositoryPath))
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.repositoryPath, forType: .string)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
            Text("Your notes are never deleted automatically.")
        }
        .font(.caption())
        .foregroundStyle(Journal.inkSoft)
        .padding(.top, Journal.Space.s)
    }

    // MARK: - Actions

    private func open(_ event: ActivityEvent) {
        guard editing != event.id else { return }
        model.route = .memory(event.id)
    }

    private func beginEdit(_ event: ActivityEvent) {
        editing = event.id
        draft = event.note ?? ""
        editFocused = true
    }

    private func cancelEdit() {
        editing = nil
        draft = ""
    }

    /// Return saves. An emptied field is treated as a cancel rather than as
    /// "forget": clearing the note would silently drop the row out of this
    /// screen, and there is a labelled control for that.
    private func saveEdit(_ event: ActivityEvent) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { cancelEdit(); return }
        do {
            guard try model.store.annotate(activityId: event.id, note: text) != nil else {
                model.toast = Toast(message: "That memory is gone", isError: true)
                cancelEdit()
                Task { await load() }
                return
            }
            cancelEdit()
            model.toast = Toast(message: "Saved")
            Task { await load() }
        } catch {
            model.toast = Toast(message: "Couldn't save the note: \(error.localizedDescription)", isError: true)
        }
    }

    private func forget(_ event: ActivityEvent) {
        do {
            try model.store.deleteActivity(id: event.id)
            if editing == event.id { cancelEdit() }
            memories.removeAll { $0.id == event.id }
            model.toast = Toast(message: "Forgotten")
            Task { await load() }
        } catch {
            model.toast = Toast(message: "Couldn't forget that: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Data

    /// Reads happen off the main actor; a failure keeps what was on screen and
    /// says so, rather than blanking the grid.
    private func load() async {
        let store = model.store
        let read = await Task.detached(priority: .userInitiated) {
            () -> Result<([ActivityEvent], [ProjectNote]), Error> in
            do {
                return .success((try store.notedActivity(limit: 400), try store.allProjectNotes()))
            } catch {
                return .failure(error)
            }
        }.value

        switch read {
        case .success(let (events, notes)):
            memories = events
            projects = notes.filter { !$0.isEmpty }
            failure = nil
        case .failure(let error):
            failure = error.localizedDescription
        }
        loading = false
    }
}
