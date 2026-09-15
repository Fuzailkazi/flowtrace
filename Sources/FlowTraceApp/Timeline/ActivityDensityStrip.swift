import SwiftUI
import FlowTraceCore

/// Where in the day the things you wrote about sit.
///
/// A thin track across the working hours with a pen-coloured mark at each noted
/// event. It is drawn from the rows on screen and nothing else — no hourly
/// histogram, no "density" invented from ambient capture. The range is the
/// working day, widened when you wrote something outside it.
struct ActivityDensityStrip: View {
    let events: [ActivityEvent]
    let day: Date

    private static let defaultStart = 8
    private static let defaultEnd = 18
    /// Keeps the first and last labels inside the card.
    private let inset: CGFloat = 12
    private let trackY: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            Text("ACTIVITY (\(clock(range.start)) – \(clock(range.end)))")
                .font(.caption())
                .tracking(1.0)
                .foregroundStyle(Journal.inkSoft)

            GeometryReader { geo in
                let width = geo.size.width - inset * 2
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Journal.rule)
                        .frame(width: width, height: 3)
                        .position(x: inset + width / 2, y: trackY)

                    ForEach(Array(stride(from: range.start, through: range.end, by: 1)), id: \.self) { hour in
                        let x = inset + width * fraction(ofHour: hour)
                        Rectangle()
                            .fill(Journal.ruleFirm)
                            .frame(width: 1, height: 6)
                            .position(x: x, y: trackY + 7)
                        Text(label(forHour: hour))
                            .font(.caption(9.5))
                            .foregroundStyle(Journal.inkSoft)
                            .position(x: x, y: trackY + 20)
                    }

                    ForEach(events) { event in
                        let start = fraction(of: event.startedAt)
                        let end = fraction(of: event.endedAt ?? event.startedAt)
                        let markWidth = max(4, width * (end - start))
                        Capsule()
                            .fill(Journal.pen)
                            .frame(width: markWidth, height: 8)
                            .position(x: inset + width * start + markWidth / 2, y: trackY)
                            .help("\(event.startedAt.formatted(date: .omitted, time: .shortened)) · \(event.appName)")
                    }
                }
            }
            .frame(height: 34)
        }
        .padding(Journal.Space.l)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    // MARK: - Geometry

    /// The working day, stretched to hold anything written outside it.
    private var range: (start: Int, end: Int) {
        var start = Self.defaultStart
        var end = Self.defaultEnd
        for event in events {
            start = min(start, Int(floor(hours(event.startedAt))))
            end = max(end, Int(ceil(hours(event.endedAt ?? event.startedAt))))
        }
        start = max(0, start)
        end = min(24, max(end, start + 1))
        return (start, end)
    }

    /// Hours since the start of the day, fractional.
    private func hours(_ date: Date) -> Double {
        date.timeIntervalSince(Calendar.current.startOfDay(for: day)) / 3600
    }

    private func fraction(ofHour hour: Int) -> CGFloat {
        CGFloat(hour - range.start) / CGFloat(range.end - range.start)
    }

    private func fraction(of date: Date) -> CGFloat {
        let raw = (hours(date) - Double(range.start)) / Double(range.end - range.start)
        return CGFloat(min(1, max(0, raw)))
    }

    // MARK: - Labels

    /// "8a", "12p", "5p" — as the design labels its ticks.
    private func label(forHour hour: Int) -> String {
        let h = hour % 24
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve)\(h < 12 ? "a" : "p")"
    }

    private func clock(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
}
