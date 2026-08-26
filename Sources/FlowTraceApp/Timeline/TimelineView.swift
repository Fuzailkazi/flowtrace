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

    private var unexplained: Int { events.filter(\.isUnexplained).count }
    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
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
                        Divider().overlay(Journal.rule)
                    }
                }
            }
            .padding(.horizontal, Journal.Space.xl)
            .padding(.bottom, Journal.Space.xl)
        }
        .background(Journal.paper)
        .task(id: day) { load() }
        .onReceive(refreshTick) { _ in if isToday { load() } }
        .toolbar { toolbar }
    }

    // MARK: - Header

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                    .font(.journalTitle(25))
                    .foregroundStyle(Journal.ink)

                Spacer()

                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkSoft)
            }

            // The one number that says whether the day is accounted for.
            if unexplained > 0 {
                HStack(spacing: 6) {
                    Circle().fill(Journal.amber).frame(width: 6, height: 6)
                    Text("\(unexplained) thing\(unexplained == 1 ? "" : "s") you haven't explained")
                        .font(.observed(12))
                        .foregroundStyle(Journal.amber)
                }
            } else if !events.isEmpty {
                Text("Every entry has a reason.")
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkSoft)
            }
        }
        .padding(.top, Journal.Space.l)
        .padding(.bottom, Journal.Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Journal.ruleFirm) }
    }

    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            Text(isToday ? "Nothing written down yet." : "Nothing on this day.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)
                .padding(.top, Journal.Space.xl)

            Text(model.isRecording
                 ? "FlowTrace is watching. Switch to another app and it will appear here."
                 : "Turn on recording in Settings and your day will fill in as you work.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
                .frame(maxWidth: 420, alignment: .leading)

            if !model.isRecording {
                Button("Open Settings") { model.route = .settings }
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
