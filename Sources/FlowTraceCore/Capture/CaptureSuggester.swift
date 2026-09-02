import Foundation

/// A single best-guess answer to "why are you here?" — never a set of
/// competing options, and never anything beyond records FlowTrace already
/// stores. `text`/`source` say what was shown and where it came from, so the
/// caller can label it honestly ("Last asked: …" for an observed prompt vs.
/// plain quotes for your own words).
public struct CaptureSuggestion: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case projectNote, tabNote, agentPrompt }
    public var text: String
    public var source: Source
}

/// The three candidates `CaptureSuggester` picks among, already resolved by
/// the caller. Gathering these (scanning `leadingUp` for a `cwd`, looking up
/// a `ProjectNote`, reading a tab note) is the caller's job — this type is
/// pure priority-picking, nothing else.
public struct CaptureSuggestionInput: Sendable {
    public var projectNote: String?
    public var tabNote: String?
    public var lastAgentPrompt: String?

    public init(projectNote: String? = nil, tabNote: String? = nil, lastAgentPrompt: String? = nil) {
        self.projectNote = projectNote
        self.tabNote = tabNote
        self.lastAgentPrompt = lastAgentPrompt
    }
}

/// Picks the single best-guess answer for the Quick Capture "why are you
/// here?" field: your own project note beats your own note on the page beats
/// what you last asked an agent for. The same "silence is the correct
/// default" rule as `BriefBuilder` — when none of the three have anything to
/// say, this returns nil rather than guessing.
public enum CaptureSuggester {
    public static func suggest(_ input: CaptureSuggestionInput) -> CaptureSuggestion? {
        if let text = nonEmpty(input.projectNote) {
            return CaptureSuggestion(text: text, source: .projectNote)
        }
        if let text = nonEmpty(input.tabNote) {
            return CaptureSuggestion(text: text, source: .tabNote)
        }
        if let text = nonEmpty(input.lastAgentPrompt) {
            return CaptureSuggestion(text: text, source: .agentPrompt)
        }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
