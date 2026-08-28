import SwiftUI
import FlowTraceCore

/// The app's only main screen: a day you can read.
///
/// Deliberately not a sidebar and a list. The previous shell — All / Active /
/// Paused / Completed — was the grammar of a task manager, and it told everyone
/// the wrong thing about what this is.
struct TimelineView: View {
    @Bindable var model: AppModel
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var events: [ActivityEvent] = []
    @State private var refreshTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    /// Highlighted after being picked in the rail.
    @State private var selected: String?
    @State private var confirmingForget = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationSplitView {
            SessionsRail(model: model, day: day) { session in
                selected = session.id
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            day_
        }
    }

    private var day_: some View {
        ScrollViewReader { scroller in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                dayHeader

                if events.isEmpty {
                    empty
                } else {
                    ForEach(events) { event in
                        TimelineRow(
                            event: event,
                            onSave: { note in
                                _ = try? model.store.annotate(activityId: event.id, note: note)
                                load()
                            },
                            onDelete: {
                                try? model.store.deleteActivity(id: event.id)
                                load()
                            }
                        )
                        .id(event.id)
                        .background(
                            selected == event.id
                                ? Journal.penSoft : Color.clear
                        )
                        Divider().overlay(Journal.rule)
                    }
                }
            }
            .padding(.horizontal, Journal.Space.xl)
            .padding(.bottom, Journal.Space.xl)
        }
        .background(Journal.paper)
        .task(id: day) { load(); model.importSessions(on: day) }
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
        .toolbar { toolbar }
        .confirmationDialog(
            "Forget everything recorded on this day?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget it", role: .destructive) {
                try? model.store.deleteActivity(on: day)
                load()
                model.toast = Toast(message: "That day is gone")
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Every entry and everything you wrote about them is removed. "
                 + "Your own files are untouched.")
        }
        }
    }

    // MARK: - Header

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            HStack(alignment: .center, spacing: Journal.Space.m) {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                    .font(.journalTitle(25))
                    .foregroundStyle(Journal.ink)

                SurfaceSwitch(model: model)

                Spacer()

                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkSoft)
            }

            if !events.isEmpty {
                Text("\(events.count) note\(events.count == 1 ? "" : "s")")
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkSoft)
            }
        }
        .padding(.top, 34)
        .padding(.bottom, Journal.Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Journal.ruleFirm) }
    }

    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            Text(isToday ? "Nothing written down yet." : "Nothing written on this day.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)
                .padding(.top, Journal.Space.xl)

            Text("Press \(model.captureTrigger.displayString) wherever you are and write "
                 + "why you're there. That's what appears here — the things you chose to "
                 + "write down, not everything you touched.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
                .frame(maxWidth: 440, alignment: .leading)

            if !CaptureTrigger.hasBeenChosen {
                Button("Pick a key") { model.route = .settings }
                    .controlSize(.small)
                    .padding(.top, Journal.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                shift(by: -1)
            } label: { Image(systemName: "chevron.left") }
                .help("The day before")

            Button {
                shift(by: 1)
            } label: { Image(systemName: "chevron.right") }
                .disabled(isToday)
                .help("The day after")

            Button("Today") { day = Calendar.current.startOfDay(for: Date()) }
                .disabled(isToday)

            Menu {
                Button("Forget this day", role: .destructive) { confirmingForget = true }
                    .disabled(events.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
        }
    }

    private func shift(by days: Int) {
        guard let moved = Calendar.current.date(byAdding: .day, value: days, to: day)
        else { return }
        day = min(moved, Calendar.current.startOfDay(for: Date()))
    }

    private func load() {
        events = (try? model.store.activity(on: day)) ?? []
    }
}
