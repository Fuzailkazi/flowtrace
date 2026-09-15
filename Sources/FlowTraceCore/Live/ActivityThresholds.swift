import Foundation

/// How long a piece of work has to be quiet before FlowTrace says something
/// about it.
///
/// These are hypotheses, not product truth. They live in one named place, with
/// one instance the whole app reads, so that tuning them is a single edit and
/// so that a test can pin an unusual boundary without reaching into the reader.
///
/// The shape is what matters more than the numbers: an agent that wrote
/// something in the last couple of minutes is mid-turn, one that wrote within
/// the hour is almost certainly waiting on you, one quiet for half a day is
/// something you walked away from. Only the last of those is worth
/// interrupting someone about.
public struct ActivityThresholds: Sendable, Equatable {
    /// Written to this recently — still mid-turn.
    public var working: TimeInterval
    /// Recently enough that you probably meant to come back.
    public var waiting: TimeInterval
    /// Past this, calling it "waiting for you" stops being true.
    public var quiet: TimeInterval

    public init(working: TimeInterval = 120, waiting: TimeInterval = 3_600, quiet: TimeInterval = 43_200) {
        self.working = working
        self.waiting = waiting
        self.quiet = quiet
    }

    public static let `default` = ActivityThresholds()

    /// Where an age falls. The only place the boundaries are compared, so
    /// there is one story about what "forgotten" means.
    public func state(forAge age: TimeInterval) -> LiveAgent.State {
        if age < working { return .working }
        if age < waiting { return .waiting }
        if age < quiet { return .quiet }
        return .forgotten
    }
}
