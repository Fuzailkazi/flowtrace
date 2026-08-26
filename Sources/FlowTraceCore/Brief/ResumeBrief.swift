import Foundation

/// What you need to pick a repository back up, written for an agent to read.
///
/// Deliberately prose, not a table: this is injected into a model's context as
/// the opening of a session, and prose is what a model resumes from. The human
/// rendering is the same text — if it doesn't read well to you, it won't work as
/// a prompt either.
public struct ResumeBrief: Equatable, Sendable {
    public var repositoryName: String
    public var repositoryPath: String
    public var branch: String
    public var daysSinceActivity: Int
    public var hoursSinceActivity: Int

    public var changedFiles: [String]
    public var uncommittedCount: Int
    public var unpushedCount: Int
    public var lastCommitSubject: String?

    /// The last things you asked an agent here, oldest first, already redacted.
    public var recentPrompts: [String]
    /// Title the agent gave its last session in this repository.
    public var sessionTitle: String?
    /// How many credential-shaped strings were removed on the way in.
    public var redactionCount: Int

    public init(
        repositoryName: String,
        repositoryPath: String,
        branch: String,
        daysSinceActivity: Int,
        hoursSinceActivity: Int,
        changedFiles: [String] = [],
        uncommittedCount: Int = 0,
        unpushedCount: Int = 0,
        lastCommitSubject: String? = nil,
        recentPrompts: [String] = [],
        sessionTitle: String? = nil,
        redactionCount: Int = 0
    ) {
        self.repositoryName = repositoryName
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.daysSinceActivity = daysSinceActivity
        self.hoursSinceActivity = hoursSinceActivity
        self.changedFiles = changedFiles
        self.uncommittedCount = uncommittedCount
        self.unpushedCount = unpushedCount
        self.lastCommitSubject = lastCommitSubject
        self.recentPrompts = recentPrompts
        self.sessionTitle = sessionTitle
        self.redactionCount = redactionCount
    }

    /// "2 days", "5 hours" — the unit people actually use for how cold something is.
    var elapsedPhrase: String {
        if daysSinceActivity >= 1 {
            return daysSinceActivity == 1 ? "yesterday" : "\(daysSinceActivity) days ago"
        }
        if hoursSinceActivity >= 1 {
            return hoursSinceActivity == 1 ? "an hour ago" : "\(hoursSinceActivity) hours ago"
        }
        return "earlier today"
    }

    /// Source files first — a lockfile in this list wastes the reader's attention.
    var notableFiles: [String] {
        let meaningful = changedFiles.filter { !DetectionEvidence.isGenerated($0) }
        let pool = meaningful.isEmpty ? changedFiles : meaningful
        return pool.prefix(6).map { path in
            // git reports an untracked directory with a trailing slash; showing
            // just its last component makes a folder look like a file.
            path.hasSuffix("/")
                ? ((path.dropLast() as NSString).lastPathComponent) + "/"
                : (path as NSString).lastPathComponent
        }
    }

    /// The brief as an agent reads it.
    ///
    /// Kept under roughly 400 tokens: every token spent here is one taken from the
    /// work itself, and a preamble that crowds out the task defeats its purpose.
    public func render() -> String {
        var lines: [String] = []
        lines.append("You worked on \(repositoryName) \(elapsedPhrase), on branch \(branch).")

        if let sessionTitle, !sessionTitle.isEmpty {
            lines.append("That session was about: \(sessionTitle).")
        }

        var state: [String] = []
        if uncommittedCount > 0 {
            let names = notableFiles
            state.append(names.isEmpty
                ? "\(uncommittedCount) uncommitted file\(uncommittedCount == 1 ? "" : "s")"
                : "\(uncommittedCount) uncommitted file\(uncommittedCount == 1 ? "" : "s") "
                  + "(\(names.joined(separator: ", ")))")
        }
        if unpushedCount > 0 {
            state.append("\(unpushedCount) commit\(unpushedCount == 1 ? "" : "s") not yet pushed")
        }
        if !state.isEmpty {
            lines.append("You left " + state.joined(separator: ", and ") + ".")
        }

        if let lastCommitSubject, !lastCommitSubject.isEmpty {
            lines.append("Your last commit was \"\(lastCommitSubject)\".")
        }

        if !recentPrompts.isEmpty {
            lines.append("")
            lines.append("The last things you asked an agent in this repository:")
            for prompt in recentPrompts {
                lines.append("  · \(prompt)")
            }
        }

        if redactionCount > 0 {
            lines.append("")
            lines.append("(\(redactionCount) credential-shaped string"
                         + "\(redactionCount == 1 ? " was" : "s were") removed from the above.)")
        }

        return lines.joined(separator: "\n")
    }

    /// The `SessionStart` hook payload Claude Code expects.
    public func hookPayload() -> String {
        let context = "Context from FlowTrace — where this repository was left:\n\n"
            + render()
            + "\n\nUse this only if the user's request relates to it; do not act on it unprompted."

        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": context,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Rough token count, for keeping the injection honest about its cost.
    public var estimatedTokens: Int {
        max(1, render().count / 4)
    }
}
