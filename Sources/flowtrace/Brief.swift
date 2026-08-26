import Foundation
import ArgumentParser
import FlowTraceCore

/// Prints where a repository was left, in a form an agent can resume from.
///
/// This is the surface that runs before every agent session, so two properties
/// matter more than features: it must be fast, and it must stay silent when it
/// has nothing worth saying.
struct Brief: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show where this repository was left, ready to hand to an agent."
    )

    enum Format: String, ExpressibleByArgument {
        /// Plain prose, for reading and for pasting into an agent.
        case text
        /// The SessionStart hook payload Claude Code expects.
        case hook
    }

    @Option(name: .long, help: "Repository path. Defaults to the current directory.")
    var repo: String?

    @Option(name: .long, help: "text or hook")
    var format: Format = .text

    @Flag(name: .long, help: "Say nothing at all when there is no brief.")
    var quiet = false

    @Flag(name: .long, help: "Don't record that a brief was shown.")
    var noLog = false

    @Option(name: .long, help: "Stay silent if the repository was touched within this many hours.")
    var quietHours: Double = 2

    func run() throws {
        let path = repo ?? FileManager.default.currentDirectoryPath

        var config = BriefConfig()
        config.quietHours = quietHours

        // The store is optional here: the brief itself needs nothing but git and
        // transcripts, and a hook that fails because a database is missing is a
        // hook that breaks `claude` for everyone who never opened the app.
        let store = try? openStore()
        let cache = store.map(StoreSessionCache.init(store:))

        guard let brief = BriefBuilder().build(
            repositoryPath: path, config: config, cache: cache
        ) else {
            cache?.flush()
            if format == .hook { print("{}") }
            else if !quiet { print(Term.dim("Nothing to resume here.")) }
            throw ExitCode(quiet || format == .hook ? 0 : 1)
        }
        cache?.flush()

        if !noLog, let store {
            try? store.recordBriefShown(
                repositoryPath: brief.repositoryPath,
                repositoryName: brief.repositoryName,
                estimatedTokens: brief.estimatedTokens
            )
        }

        switch format {
        case .hook:
            print(brief.hookPayload())
        case .text:
            print("")
            print(render(brief))
            print("")
        }
    }

    /// The same words as `render()`, with colour for a terminal.
    private func render(_ brief: ResumeBrief) -> String {
        var out = brief.render()
        out = out.replacingOccurrences(
            of: brief.repositoryName, with: Term.bold(brief.repositoryName)
        )
        return out
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.hasPrefix("  · ") ? Term.dim(String(line)) : String(line)
            }
            .joined(separator: "\n")
    }
}
