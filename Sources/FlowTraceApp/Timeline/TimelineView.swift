import SwiftUI
import FlowTraceCore

/// A day you can read.
///
/// The things you wrote about, in the order they happened — not everything you
/// touched. The shell owns the sidebar and the top bar; this is the page.
struct TimelineView: View {
    @Bindable var model: AppModel
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var events: [ActivityEvent] = []
    @State private var refreshTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    /// Highlighted after being pointed at — from a repository chip or a memory.
    @State private var selected: String?
    /// One app's rows only, or every app when nil. Local to the loaded day.
    @State private var appFilter: String?
    @State private var confirmingForget = false
    /// True until the first read of this day comes back, so an unread day and an
    /// empty one don't look the same.
    @State private var loading = true
    /// A read that failed. Kept until one succeeds — an empty day and an
    /// unreadable one are different things to be told.
    @State private var failure: String?

    private static let contentWidth: CGFloat = 1152

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Journal.Space.xl) {
                    header

                    if let failure {
                        LoadFailureNotice(message: failure) { load() }
                    }

                    if loading && events.isEmpty {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Journal.Space.xxl)
                    } else if events.isEmpty {
                        if failure == nil { empty }
                    } else {
                        filters
                        ActivityDensityStrip(events: events, day: day)
                        SessionsRail(model: model, day: day) { session in
                            selected = session.id
                        }
                        stream
                        endMarker
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, Journal.Space.xxl)
                .frame(maxWidth: Self.contentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(Journal.paper)
            .onAppear(perform: takeFocus)
            .task(id: day) {
                loading = true
                load()
                model.importSessions(on: day)
            }
            .onReceive(refreshTick) { _ in
                guard isToday else { return }
                load()
                model.importSessions(on: day)
            }
            .onChange(of: model.activityRevision) { _, _ in load() }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.3)) { scroller.scrollTo(id, anchor: .center) }
                // The highlight is a pointer, not a selection — it fades on its own.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.easeOut(duration: 0.5)) { selected = nil }
                }
            }
            .confirmationDialog(
                "Forget everything recorded on this day?",
                isPresented: $confirmingForget,
                titleVisibility: .visible
            ) {
                Button("Forget it", role: .destructive, action: forgetDay)
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Every entry and everything you wrote about them is removed. "
                     + "Your own files are untouched.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Journal.Space.l) {
            VStack(alignment: .leading, spacing: Journal.Space.s) {
                Text("YOUR DAY")
                    .font(.caption())
                    .tracking(1.0)
                    .foregroundStyle(Journal.inkSoft)
                Text("What were you doing?")
                    .font(.journalTitle(28))
                    .tracking(-0.4)
                    .foregroundStyle(Journal.ink)
                Text("The moments you wrote about, in the order they happened.")
                    .font(.observed(13.5))
                    .foregroundStyle(Journal.inkMid)
            }

            Spacer(minLength: Journal.Space.l)

            dayControl
        }
    }

    /// Which day, and the way to another one.
    private var dayControl: some View {
        HStack(spacing: Journal.Space.xs) {
            iconButton("chevron.left", help: "The day before") { shift(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            VStack(spacing: 2) {
                Text(dayLabel)
                    .font(.observed(12.5, weight: .medium))
                    .foregroundStyle(Journal.ink)
                Text("\(events.count) note\(events.count == 1 ? "" : "s")")
                    .font(.caption(9.5))
                    .foregroundStyle(Journal.inkSoft)
            }
            .frame(minWidth: 112)

            iconButton("chevron.right", help: "The day after") { shift(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(isToday)

            if !isToday {
                Rectangle().fill(Journal.rule).frame(width: 1, height: 20)
                    .padding(.horizontal, Journal.Space.xs)
                Button("Jump to today") { day = Calendar.current.startOfDay(for: Date()) }
                    .buttonStyle(.plain)
                    .font(.observed(11.5, weight: .medium))
                    .foregroundStyle(Journal.pen)
                    .padding(.horizontal, Journal.Space.s)
            }

            Rectangle().fill(Journal.rule).frame(width: 1, height: 20)
                .padding(.horizontal, Journal.Space.xs)

            Menu {
                Button("Forget this day", role: .destructive) { confirmingForget = true }
                    .disabled(events.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Journal.inkMid)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("More")
        }
        .padding(.horizontal, Journal.Space.s)
        .padding(.vertical, 6)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Journal.inkMid)
        .help(help)
    }

    /// "Today, Sep 15" / "Yesterday, Sep 14" / "Monday, Sep 8".
    private var dayLabel: String {
        let date = day.formatted(.dateTime.month(.abbreviated).day())
        if isToday { return "Today, \(date)" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday, \(date)" }
        return "\(day.formatted(.dateTime.weekday(.wide))), \(date)"
    }

    // MARK: - Filters

    /// One chip per app that appears on this day. A filter over what is loaded,
    /// never a different query.
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip("All", selected: appFilter == nil) { appFilter = nil }
                ForEach(apps, id: \.self) { app in
                    filterChip(app, selected: appFilter == app) {
                        appFilter = appFilter == app ? nil : app
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func filterChip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.observed(12, weight: .medium))
                .foregroundStyle(selected ? Journal.paper : Journal.inkMid)
                .padding(.horizontal, Journal.Space.m)
                .padding(.vertical, 5)
                .background(
                    selected ? Journal.ink : Journal.wash,
                    in: RoundedRectangle(cornerRadius: Journal.Radius.chip)
                )
                .contentShape(RoundedRectangle(cornerRadius: Journal.Radius.chip))
        }
        .buttonStyle(.plain)
    }

    /// Apps on the day, most-written-about first.
    private var apps: [String] {
        let counts = Dictionary(grouping: events, by: \.appName).mapValues(\.count)
        return counts.keys.sorted { a, b in
            counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b
        }
    }

    private var visibleEvents: [ActivityEvent] {
        let filtered = appFilter.map { app in events.filter { $0.appName == app } } ?? events
        return filtered.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - The stream

    private enum PartOfDay: Int, CaseIterable {
        case evening, afternoon, morning

        var label: String {
            switch self {
            case .morning: "MORNING"
            case .afternoon: "AFTERNOON"
            case .evening: "EVENING"
            }
        }

        init(_ date: Date) {
            let hour = Calendar.current.component(.hour, from: date)
            self = hour < 12 ? .morning : hour < 18 ? .afternoon : .evening
        }
    }

    /// Newest part of the day first, newest row first within it — as the design reads.
    private var sections: [(part: PartOfDay, rows: [ActivityEvent])] {
        let grouped = Dictionary(grouping: visibleEvents) { PartOfDay($0.startedAt) }
        return PartOfDay.allCases.compactMap { part in
            grouped[part].map { (part, $0) }
        }
    }

    @ViewBuilder
    private var stream: some View {
        if visibleEvents.isEmpty, let app = appFilter {
            Text("Nothing written about \(app) on this day.")
                .font(.observed(13))
                .foregroundStyle(Journal.inkSoft)
                .padding(.leading, 64 + Journal.Space.l)
        } else {
            ForEach(sections, id: \.part) { section in
                VStack(alignment: .leading, spacing: 0) {
                    sectionDivider(section.part.label)
                    ForEach(section.rows) { event in
                        TimelineRow(
                            event: event,
                            isHighlighted: selected == event.id,
                            onSave: { note in annotate(event, note: note) },
                            onDelete: { forget(event) }
                        )
                        .id(event.id)
                    }
                }
            }
        }
    }

    private func sectionDivider(_ label: String) -> some View {
        HStack(spacing: Journal.Space.l) {
            Text(label)
                .font(.caption(10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Journal.inkSoft)
                .frame(width: 64, alignment: .trailing)
            Circle().fill(Journal.rule).frame(width: 8, height: 8)
            Rectangle().fill(Journal.rule).frame(height: 1)
        }
        .padding(.bottom, Journal.Space.s)
    }

    private var endMarker: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
            Text("End of what you wrote for \(dayLabel)")
                .font(.caption(10))
                .tracking(0.4)
        }
        .foregroundStyle(Journal.inkSoft)
        .frame(maxWidth: .infinity)
        .padding(.top, Journal.Space.s)
    }

    // MARK: - Nothing yet

    private var empty: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            Text(isToday ? "Nothing written down yet." : "Nothing written on this day.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)

            Text("Press \(model.captureTrigger.displayString) wherever you are and write "
                 + "why you're there. That's what appears here — the things you chose to "
                 + "write down, not everything you touched.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
                .frame(maxWidth: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)


        }
        .padding(Journal.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    // MARK: - Moving between days

    private func shift(by days: Int) {
        guard let moved = Calendar.current.date(byAdding: .day, value: days, to: day)
        else { return }
        day = min(moved, Calendar.current.startOfDay(for: Date()))
    }

    /// "View in Timeline" from a memory: open that day and point at that row.
    private func takeFocus() {
        guard let focus = model.timelineFocus else { return }
        model.timelineFocus = nil
        appFilter = nil
        day = Calendar.current.startOfDay(for: focus.day)
        load()
        // Let the rows lay out before asking the scroller to find one.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            selected = focus.eventId
        }
    }

    // MARK: - Data

    private func load() {
        do {
            events = try model.store.activity(on: day)
            failure = nil
        } catch {
            // Leave `events` alone: on a refresh tick the day is already on
            // screen and is still the last thing we truthfully read.
            failure = error.localizedDescription
        }
        loading = false
        // A filter for an app that isn't on this day filters everything out.
        if let app = appFilter, !events.contains(where: { $0.appName == app }) {
            appFilter = nil
        }
    }

    private func annotate(_ event: ActivityEvent, note: String) {
        do {
            _ = try model.store.annotate(activityId: event.id, note: note)
            load()
        } catch {
            model.toast = Toast(message: "Couldn't save that note", isError: true)
        }
    }

    private func forget(_ event: ActivityEvent) {
        do {
            try model.store.deleteActivity(id: event.id)
            load()
        } catch {
            model.toast = Toast(message: "Couldn't forget that", isError: true)
        }
    }

    private func forgetDay() {
        do {
            try model.store.deleteActivity(on: day)
            load()
            model.toast = Toast(message: "That day is gone")
        } catch {
            model.toast = Toast(message: "Couldn't forget that day", isError: true)
        }
    }
}
