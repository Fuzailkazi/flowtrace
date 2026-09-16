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

        return AttentionSections(
            continueWork: Array(continuing),
            recent: Array(recent),
            background: unique.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }
}

public extension LiveProject {
    /// The newest turn attributable to the person, never the agent heartbeat.
    var lastHumanActivityAt: Date? {
        readAgents.compactMap(\.lastHumanActivityAt).max()
    }
}
