import SwiftUI
import AppKit
import FlowTraceCore

// Pieces shared by the Memories grid and the Memory Detail screen: the app icon
// lookup, the words used to describe a row, and the small chips and buttons the
// design draws everywhere.

// MARK: - App icons

/// The real icon of the app a row came from, or an SF Symbol for its kind.
///
/// Looked up through NSWorkspace and kept in a main-actor cache keyed by bundle
/// id, so a grid of forty cards asks the system once per app, not once per card.
struct AppIconView: View {
    let bundleIdentifier: String?
    let kind: ActivityKind
    var size: CGFloat = 18

    var body: some View {
        if let image = AppIconCache.icon(for: bundleIdentifier) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: Self.symbol(for: kind))
                .font(.system(size: size * 0.72, weight: .medium))
                .foregroundStyle(Journal.inkMid)
                .frame(width: size, height: size)
        }
    }

    static func symbol(for kind: ActivityKind) -> String {
        switch kind {
        case .app: "macwindow"
        case .browserTab: "globe"
        case .agentSession: "terminal"
        case .git: "arrow.triangle.branch"
        }
    }
}

@MainActor
enum AppIconCache {
    /// `nil` stored under a key means "asked, and the app isn't installed".
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let known = cache[bundleIdentifier] { return known }
        let found = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleIdentifier] = found
        return found
    }
}

// MARK: - Words for a row

enum MemoryFormat {
    /// The line that makes a memory recognisable: what you were looking at,
    /// failing that where you were, failing that just the app.
    static func title(_ event: ActivityEvent) -> String {
        if let target = event.target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            return target
        }
        if let place = event.metadata["place"], !place.isEmpty { return place }
        if let about = event.metadata["about"], !about.isEmpty { return about }
        return event.appName
    }

    static func place(_ event: ActivityEvent) -> String? {
        if let place = event.metadata["place"], !place.isEmpty { return place }
        if let cwd = event.metadata["cwd"], !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return nil
    }

    static func hasPlace(_ event: ActivityEvent) -> Bool {
        !(event.metadata["place"] ?? "").isEmpty || !(event.metadata["cwd"] ?? "").isEmpty
    }

    /// "stripe.com" from a full address; nil when there is no address.
    static func host(_ event: ActivityEvent) -> String? {
        guard let raw = event.url, let url = URL(string: raw), var host = url.host else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The mono footer on a card: host, else place, else message count.
    static func footer(_ event: ActivityEvent) -> String? {
        if let host = host(event) { return host }
        if let place = place(event) { return place }
        if event.kind == .agentSession, !event.durationLabel.isEmpty { return event.durationLabel }
        return nil
    }

    /// What the `url`/`target` field *is*, per kind. Written so the reader knows
    /// where the words came from.
    static func kindCaption(_ kind: ActivityKind) -> String {
        switch kind {
        case .app: "window title"
        case .browserTab: "page"
        case .agentSession: "session"
        case .git: "repository"
        }
    }

    /// "Today · 2:14 PM", "Yesterday", "Sep 12", "Sep 12, 2025".
    static func dayCaption(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today · \(date.formatted(date: .omitted, time: .shortened))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "Sep 12, 4:32 PM" — a fuller stamp for the detail screen.
    static func momentCaption(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "16:32:18" — the status-strip time in the design.
    static func preciseClock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// "(4m before)", "(3m after)", "(same minute)".
    static func offsetCaption(_ date: Date, from anchor: Date) -> String {
        let minutes = Int((date.timeIntervalSince(anchor) / 60).rounded())
        if minutes == 0 { return "(same minute)" }
        let magnitude = abs(minutes)
        let span = magnitude < 60 ? "\(magnitude)m" : String(format: "%dh %02dm", magnitude / 60, magnitude % 60)
        return minutes < 0 ? "(\(span) before)" : "(\(span) after)"
    }

    static func shortId(_ id: String) -> String {
        String(id.prefix(8)).uppercased()
    }
}

// MARK: - Small surfaces

/// A wash-filled chip, optionally with an icon or an app icon leading it.
struct WashChip<Leading: View>: View {
    let text: String
    var mono = false
    var fill: Color = Journal.wash
    var ink: Color = Journal.inkMid
    @ViewBuilder var leading: Leading

    init(
        _ text: String,
        mono: Bool = false,
        fill: Color = Journal.wash,
        ink: Color = Journal.inkMid,
        @ViewBuilder leading: () -> Leading = { EmptyView() }
    ) {
        self.text = text
        self.mono = mono
        self.fill = fill
        self.ink = ink
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 5) {
            leading
            Text(text)
                .font(mono ? .caption() : .observed(11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(fill, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
    }
}

/// A small icon-led button on a wash fill: the top-bar actions in the design.
struct WashButton: View {
    let title: String
    let systemImage: String
    var ink: Color = Journal.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.observed(12, weight: .medium))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// A bare icon button for the hover row on a card.
struct IconButton: View {
    let systemImage: String
    let help: String
    var ink: Color = Journal.inkMid
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 24, height: 24)
                .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The design's card: white, 12pt radius, a shadow that is barely there.
struct MemoryCardSurface: ViewModifier {
    var padding: CGFloat = Journal.Space.l
    var radius: CGFloat = Journal.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }
}

extension View {
    func memoryCard(padding: CGFloat = Journal.Space.l, radius: CGFloat = Journal.Radius.card) -> some View {
        modifier(MemoryCardSurface(padding: padding, radius: radius))
    }
}

/// Tracked uppercase eyebrow, as the design sets section labels.
struct Eyebrow: View {
    let text: String
    var ink: Color = Journal.inkSoft

    var body: some View {
        Text(text.uppercased())
            .font(.caption())
            .tracking(1.0)
            .foregroundStyle(ink)
    }
}
