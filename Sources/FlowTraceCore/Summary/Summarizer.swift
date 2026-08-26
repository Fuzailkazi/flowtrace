import Foundation

/// Everything a summary is allowed to draw on. Nothing else is in scope —
/// a summary must be traceable to records the user can open and check.
public struct SummaryInput: Sendable {
    public var thread: WorkThread
    public var tabs: [BrowserContext]
    public var code: [CodeContext]
    public var notes: [Note]
    public var timeline: [TimelineEvent]
    /// Fresh git state per repository, when it could be read.
    public var repoChanges: [String: RepoChange]

    public init(
        thread: WorkThread,
        tabs: [BrowserContext] = [],
        code: [CodeContext] = [],
        notes: [Note] = [],
        timeline: [TimelineEvent] = [],
        repoChanges: [String: RepoChange] = [:]
    ) {
        self.thread = thread
        self.tabs = tabs
        self.code = code
        self.notes = notes
        self.timeline = timeline
        self.repoChanges = repoChanges
    }
}

public struct ThreadSummary: Sendable {
    public var about: String
    public var recently: [String]
    public var importantItems: [String]
    public var likelyNextStep: String
    /// Plain-language statement of what this summary was built from, shown
    /// alongside it so the user never has to guess.
    public var basedOn: String

    public var isEmpty: Bool {
        about.isEmpty && recently.isEmpty && importantItems.isEmpty
    }
}

public protocol Summarizer: Sendable {
    func summarize(_ input: SummaryInput) -> ThreadSummary
}

/// Builds a summary from stored records only.
///
/// It states what is there and nothing more: no inference about what the user
/// meant, no invented activity, no guesses about decisions. If a fact isn't in
/// the database it doesn't appear. This is the shipping summarizer; the protocol
/// exists so a model-backed one can be added later without changing callers.
public struct DeterministicSummarizer: Summarizer {
    public init() {}

    public func summarize(_ input: SummaryInput) -> ThreadSummary {
        ThreadSummary(
            about: about(input),
            recently: recently(input),
            importantItems: importantItems(input),
            likelyNextStep: likelyNextStep(input),
            basedOn: basedOn(input)
        )
    }

    private func about(_ input: SummaryInput) -> String {
        let thread = input.thread
        var sentences: [String] = []

        if !thread.intent.isEmpty {
            sentences.append("You started this because: \(thread.intent)")
        } else if !thread.description.isEmpty {
            sentences.append(thread.description)
        }

        if let evidence = thread.detectionEvidence {
            sentences.append(
                "FlowTrace found it in \(evidence.repositoryName) on \(evidence.branch) — "
                + evidence.reasons.joined(separator: ", ") + "."
            )
        }

        let repositories = Set(input.code.map(\.repositoryName)).sorted()
        if !repositories.isEmpty, thread.detectionEvidence == nil {
            sentences.append("It covers \(list(repositories)).")
        }

        if sentences.isEmpty {
            sentences.append("No intent recorded yet for \"\(thread.title)\".")
        }
        return sentences.joined(separator: " ")
    }

    private func recently(_ input: SummaryInput) -> [String] {
        var lines: [String] = []

        for event in input.timeline.prefix(5) {
            var line = "\(relative(event.createdAt)) — \(event.title)"
            if !event.description.isEmpty {
                line += ": \(AgentSession.condense(event.description, limit: 100))"
            }
            lines.append(line)
        }

        // Anything that moved in a repository since it was last captured.
        for (name, change) in input.repoChanges.sorted(by: { $0.key < $1.key })
        where !change.isEmpty {
            lines.append("\(name) changed since you left — \(change.summaryLines.joined(separator: ", "))")
        }

        if lines.isEmpty { lines.append("Nothing has happened on this thread yet.") }
        return lines
    }

    private func importantItems(_ input: SummaryInput) -> [String] {
        var items: [String] = []

        for context in input.code.prefix(4) {
            var line = context.repositoryName
            if let branch = context.branch { line += " · \(branch)" }
            if context.dirtyFileCount > 0 {
                line += " · \(context.dirtyFileCount) uncommitted"
            }
            if let agent = context.agentName { line += " · \(agent.label)" }
            items.append(line)
        }

        // Tabs the user bothered to annotate are the ones they cared about.
        let annotated = input.tabs.filter { !$0.note.isEmpty }
        for tab in (annotated.isEmpty ? Array(input.tabs.prefix(4)) : Array(annotated.prefix(4))) {
            items.append(tab.note.isEmpty
                ? "\(tab.pageTitle) (\(tab.host))"
                : "\(tab.pageTitle) — \(tab.note)")
        }

        for note in input.notes.filter(\.isDecision).prefix(3) {
            items.append("Decision: \(AgentSession.condense(note.content, limit: 120))")
        }

        if items.isEmpty { items.append("Nothing linked to this thread yet.") }
        return items
    }

    private func likelyNextStep(_ input: SummaryInput) -> String {
        let thread = input.thread
        if thread.isBlocked, let blocker = thread.blocker {
            return "Blocked: \(blocker)"
        }
        if !thread.nextStep.isEmpty { return thread.nextStep }

        // Fall back to the most recent next step recorded on a linked repository.
        if let fromCode = input.code.first(where: { !$0.nextStep.isEmpty })?.nextStep {
            return fromCode
        }
        if let evidence = thread.detectionEvidence, let prompt = evidence.lastPrompt {
            return "Last thing you asked an agent here: \(prompt)"
        }
        return "No next step recorded."
    }

    private func basedOn(_ input: SummaryInput) -> String {
        var parts: [String] = []
        if !input.code.isEmpty { parts.append(count(input.code.count, "repository", "repositories")) }
        if !input.tabs.isEmpty { parts.append(count(input.tabs.count, "tab", "tabs")) }
        if !input.notes.isEmpty { parts.append(count(input.notes.count, "note", "notes")) }
        if !input.timeline.isEmpty { parts.append(count(input.timeline.count, "activity entry", "activity entries")) }

        guard !parts.isEmpty else {
            return "Built from this thread's own fields. Nothing else is linked to it yet."
        }
        return "Built only from what's stored on this thread: \(list(parts)). No network request was made."
    }

    // MARK: - Wording

    private func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and \(items[items.count - 1])"
        }
    }

    private func relative(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...30: return "\(days)d ago"
        default: return "\(days / 30)mo ago"
        }
    }
}
