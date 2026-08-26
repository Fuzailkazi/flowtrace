import Foundation
import ArgumentParser
import FlowTraceCore

@main
struct FlowTraceCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flowtrace",
        abstract: "Find the work you abandoned, and pick it back up.",
        discussion: """
        FlowTrace reads your coding-agent transcripts and git state — read-only, \
        on this machine only — and works out which pieces of work were started \
        and never finished.
        """,
        version: "0.1.0",
        subcommands: [Scan.self, List.self, Attach.self, Resume.self, Serve.self, Seed.self, Brief.self, Verdict.self]
    )
}

// MARK: - Shared helpers

enum Term {
    static var useColor: Bool = isatty(fileno(stdout)) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func style(_ text: String, _ code: String) -> String {
        useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ t: String) -> String { style(t, "1") }
    static func dim(_ t: String) -> String { style(t, "2") }
    static func red(_ t: String) -> String { style(t, "31") }
    static func yellow(_ t: String) -> String { style(t, "33") }
    static func cyan(_ t: String) -> String { style(t, "36") }
    static func green(_ t: String) -> String { style(t, "32") }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        default: return "\(days)d ago"
        }
    }
}

func openStore() throws -> Store {
    try Store()
}
