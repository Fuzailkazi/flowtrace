import Foundation

/// The last reading of what is running, kept so that two screens showing the
/// same places agree about them.
///
/// Now takes a census every few seconds. When the user opens one of its rows,
/// the recall screen needs the same facts — is something still running here,
/// how long have you been away — and it has two bad options and one good one.
/// It can take its own census, which costs the best part of a second in
/// subprocesses and can disagree with the row the user is looking at. It can
/// take nothing, which is what it did: opening a place from a fresh launch
/// showed no live state at all, so the same place looked different depending on
/// how you arrived at it. Or it can be handed the reading Now already took.
///
/// This is that handoff. Deliberately a value in memory and nothing else: it is
/// a few seconds old at most, it is rebuilt on every launch, and writing it
/// down would create a second, slower source of truth about processes that have
/// very likely already exited.
public struct LiveCensus: Sendable {
    public var projects: [LiveProject]
    /// When this reading was taken. The reason the type exists rather than a
    /// bare array: without it nothing downstream can tell a reading from a
    /// second ago from one taken before lunch.
    public var capturedAt: Date

    public init(projects: [LiveProject] = [], capturedAt: Date = Date()) {
        self.projects = projects
        self.capturedAt = capturedAt
    }

    /// Nothing has been read yet. Distinct from a census that found nothing
    /// running, which is a real and different answer.
    public static let none = LiveCensus(projects: [], capturedAt: .distantPast)

    /// Records a reading, or refuses to.
    ///
    /// A census of running agents is built partly from transcripts, so holding
    /// one is holding the product of a permission. When observation is not
    /// permitted this returns nothing and, being a value, replaces whatever was
    /// held before — so a reading taken while a source was switched on cannot
    /// outlive the switch being turned off.
    public static func recorded(_ projects: [LiveProject], permitted: Bool) -> LiveCensus {
        permitted ? LiveCensus(projects: projects) : .none
    }

    public var hasBeenTaken: Bool { capturedAt != .distantPast }

    public var age: TimeInterval { Date().timeIntervalSince(capturedAt) }

    /// Recent enough to present as what is happening now.
    ///
    /// Generous relative to Now's own refresh, because the cost of being a few
    /// seconds behind is nil and the cost of blanking the screen is that the
    /// place appears to change when you open it.
    public var isFresh: Bool { hasBeenTaken && age < 120 }

    /// Worth showing, but old enough that the screen should say when it was
    /// taken rather than imply it is live.
    public var isStale: Bool { hasBeenTaken && !isFresh }

    public func project(at path: String) -> LiveProject? {
        let wanted = FilePathCanon.canonical(path)
        return projects.first { FilePathCanon.canonical($0.path) == wanted }
    }

    public var forgottenProjects: [LiveProject] {
        projects.filter(\.isForgotten)
    }

    public var forgottenWorkCount: Int {
        forgottenProjects.count
    }

    public var firstForgottenProject: LiveProject? {
        forgottenProjects.first
    }

    public var menuBarStatusText: String? {
        guard forgottenWorkCount > 0 else { return nil }
        return "\(forgottenWorkCount) forgotten"
    }

    /// "a moment ago", "18 minutes ago" — how the screen says how old this is.
    public var takenLabel: String? {
        guard hasBeenTaken else { return nil }
        if age < 90 { return "a moment ago" }
        return LiveState.duration(age) + " ago"
    }
}
