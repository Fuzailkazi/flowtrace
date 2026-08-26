import Foundation
import GRDB

/// What kind of thing happened. The timeline shows all of these in one column,
/// so the kind mostly decides the icon and how the subtitle is written.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    /// You were in an app. The baseline event, and the only one that needs no permission.
    case app
    /// A browser tab you had open.
    case browserTab
    /// A coding-agent session, read from its transcript after the fact.
    case agentSession
    /// Something that happened in a repository.
    case git

    public var label: String {
        switch self {
        case .app: "App"
        case .browserTab: "Tab"
        case .agentSession: "Session"
        case .git: "Repository"
        }
    }
}

/// One line on the day.
///
/// An event is a *span*, not a point: you were in VS Code from 09:12 to 10:16.
/// Storing spans rather than switches is what lets the timeline say "1h 04m"
/// instead of listing the same app forty times.
public struct ActivityEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ActivityKind

    public var startedAt: Date
    /// Nil while the span is still open — you're in this app right now.
    public var endedAt: Date?

    /// "VS Code", "Chrome", "Claude Code".
    public var appName: String
    public var bundleIdentifier: String?

    /// What you were looking at inside the app: a repository, a page title, a
    /// document name. This is the half that makes an entry recognisable.
    public var target: String?
    public var url: String?

    /// Your own words. The reason you opened it, in your voice — rendered in
    /// serif italic in the UI precisely because it is yours and not the system's.
    public var note: String?
    public var noteAt: Date?

    /// Free detail per kind: message counts, dirty file counts, session ids.
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        kind: ActivityKind,
        startedAt: Date,
        endedAt: Date? = nil,
        appName: String,
        bundleIdentifier: String? = nil,
        target: String? = nil,
        url: String? = nil,
        note: String? = nil,
        noteAt: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.target = target
        self.url = url
        self.note = note
        self.noteAt = noteAt
        self.metadata = metadata
    }

    /// True when nothing explains why this happened — the only thing the timeline
    /// marks in amber, and the thing clearing the day means.
    public var isUnexplained: Bool {
        (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var isOpen: Bool { endedAt == nil }

    /// "1h 04m", "12m", "still open" — short enough to sit at the end of a row.
    public var durationLabel: String {
        if isOpen, duration < 8 * 3600 { return "still open" }
        let minutes = Int(duration / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Two events describe the same activity when they are the same app looking at
    /// the same thing. Used to merge a flurry of switches into one span.
    public func describesSameActivity(as other: ActivityEvent) -> Bool {
        kind == other.kind
            && appName == other.appName
            && (target ?? "") == (other.target ?? "")
            && (url ?? "") == (other.url ?? "")
    }
}

extension ActivityEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "activityEvent"

    public enum Columns {
        public static let id = Column("id")
        public static let kind = Column("kind")
        public static let startedAt = Column("startedAt")
        public static let endedAt = Column("endedAt")
        public static let note = Column("note")
    }
}
