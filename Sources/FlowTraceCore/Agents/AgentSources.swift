import Foundation

/// Which agents' transcripts FlowTrace may open.
///
/// Passed as a value rather than read from a global, for two reasons. A global
/// "consent granted" flag checked deep inside a reader hides the dependency —
/// nothing in a call site tells you a permission is involved. And the CLI runs
/// in a different process from the app, where the app's `UserDefaults` are not
/// visible, so a global would be silently empty there and the CLI would stop
/// working for reasons nobody could see.
///
/// Process discovery is never represented here. `pgrep` and `lsof` read no
/// file and need no permission; what they see is gated by whether observation
/// has been agreed to at all, not by which agent is switched on.
public struct AgentSources: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let claudeCode = AgentSources(rawValue: 1 << 0)
    public static let codex = AgentSources(rawValue: 1 << 1)

    public static let all: AgentSources = [.claudeCode, .codex]
    public static let none: AgentSources = []

    /// Whether this set allows reading a given agent's transcripts.
    ///
    /// False for every agent FlowTrace cannot read anyway — Cursor, OpenCode,
    /// Gemini CLI — so a caller never has to special-case them.
    public func allows(_ agent: AgentName) -> Bool {
        switch agent {
        case .claudeCode: contains(.claudeCode)
        case .codex: contains(.codex)
        case .cursor, .openCode, .geminiCLI, .other: false
        }
    }
}
