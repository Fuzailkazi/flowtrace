import Foundation

/// Lifecycle of a Work Thread. A thread is the primary object in FlowTrace:
/// an intention, not a tab.
public enum ThreadStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, completed

    public var label: String {
        switch self {
        case .active: "Active"
        case .paused: "Paused"
        case .completed: "Completed"
        }
    }
}

public enum Priority: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    /// Sort weight, high first.
    public var weight: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        }
    }
}

/// Whether the user typed this thread or FlowTrace proposed it from evidence.
/// Detected threads always pass through user confirmation before they are stored.
public enum ThreadOrigin: String, Codable, Sendable {
    case manual, detected
}

/// Coding agents FlowTrace can attribute work to. Only `claudeCode` and `codex`
/// are auto-discoverable; the rest are captured manually via the adapter's base case.
public enum AgentName: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case cursor
    case openCode = "opencode"
    case codex
    case geminiCLI = "gemini-cli"
    case other

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .openCode: "OpenCode"
        case .codex: "Codex"
        case .geminiCLI: "Gemini CLI"
        case .other: "Other"
        }
    }

    /// True when FlowTrace can find these sessions on disk without user input.
    public var isAutoDiscoverable: Bool {
        self == .claudeCode || self == .codex
    }
}

public enum TimelineEventType: String, Codable, Sendable {
    case created, detected, resumed, paused, completed, reopened
    case noteAdded, decisionAdded
    case tabAttached, tabRemoved
    case codeAttached, codeRemoved
    case nextStepUpdated, intentUpdated
    case blockerSet, blockerCleared
}

public enum ProposalState: String, Codable, Sendable {
    case pending, accepted, dismissed
}
