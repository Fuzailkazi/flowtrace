import Foundation

/// The human-facing sections on Now.
///
/// A live process is useful background information, but it is not evidence that
/// the person is working there. This split keeps machine state out of the two
/// sections that make claims about the person's attention.
public struct AttentionSections: Sendable {
    public var continueWork: [LiveProject]
    public var recent: [LiveProject]
    public var background: [LiveProject]
}

public struct AttentionRanker: Sendable {
    public var now: Date
    public var continueWindow: TimeInterval
    public var recentWindow: TimeInterval

    public init(
        now: Date = Date(),
        continueWindow: TimeInterval = 7 * 86_400,
        recentWindow: TimeInterval = 30 * 86_400
    ) {
        self.now = now
        self.continueWindow = continueWindow
        self.recentWindow = recentWindow
    }

    public func rank(_ projects: [LiveProject]) -> AttentionSections {
        // One canonical path, even when more than one discovery route found it.
        var unique: [String: LiveProject] = [:]
        for project in projects {
            unique[FilePathCanon.canonical(project.path)] = project
        }

        let attended = unique.values.compactMap { project -> (LiveProject, Date)? in
            // Paused is an explicit instruction from the person, so even a
            // recent agent turn must not turn it into a Continue nudge.
            guard project.note?.isPaused != true else { return nil }
            guard let date = project.lastHumanActivityAt else { return nil }
            return (project, date)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.path < $1.0.path
        }

        let continuing = attended
            .filter { now.timeIntervalSince($0.1) <= continueWindow }
            .prefix(2)
            .map(\.0)
        let continuingPaths = Set(continuing.map { FilePathCanon.canonical($0.path) })

        let recent = attended
            .filter {
                let age = now.timeIntervalSince($0.1)
                return age <= recentWindow
                    && !continuingPaths.contains(FilePathCanon.canonical($0.0.path))
            }
            .prefix(6)
            .map(\.0)
        let highlightedPaths = continuingPaths.union(recent.map { FilePathCanon.canonical($0.path) })

        return AttentionSections(
            continueWork: Array(continuing),
            recent: Array(recent),
            background: unique.values
                .filter { !highlightedPaths.contains(FilePathCanon.canonical($0.path)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }
}

public extension LiveProject {
    /// The newest action attributable to the person: their agent turn or their
    /// own project note. Neither a process heartbeat nor an empty note counts.
    var lastHumanActivityAt: Date? {
        let agentTurn = readAgents.compactMap(\.lastHumanActivityAt).max()
        let noteWrite = note.flatMap { $0.isEmpty ? nil : $0.updatedAt }
        return [agentTurn, noteWrite].compactMap { $0 }.max()
    }
}
