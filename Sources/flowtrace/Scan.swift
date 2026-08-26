import Foundation
import ArgumentParser
import FlowTraceCore

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find unfinished work across your repositories and agent sessions."
    )

    @Option(name: .long, help: "Days a repository must sit untouched to count as cold.")
    var coldDays: Int = 7

    @Option(name: .long, help: "Maximum number of results to show.")
    var limit: Int = 25

    @Flag(name: .long, help: "Don't store proposals — just print what was found.")
    var dryRun = false

    @Flag(name: .long, help: "Emit JSON instead of a table.")
    var json = false

    func run() throws {
        let store = try openStore()
        let cache = StoreSessionCache(store: store)
        let detector = AbandonedWorkDetector(
            cache: cache,
            ignoredPaths: try store.ignoredPaths()
        )

        if !json {
            FileHandle.standardError.write(Data("Scanning…\n".utf8))
        }

        let result = try detector.scan(
            config: DetectorConfig(coldDays: coldDays, maxProposals: limit)
        )
        cache.flush()

        if !dryRun {
            _ = try store.mergeProposals(result.proposals)
        }

        if json {
            try printJSON(result)
        } else {
            printReport(result)
        }
    }

    private func printJSON(_ result: ScanResult) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result.proposals)
        print(String(decoding: data, as: UTF8.self))
    }

    private func printReport(_ result: ScanResult) {
        print("")
        print(Term.dim(String(
            format: "Read %d agent sessions across %d repositories in %.1fs.",
            result.sessionsScanned, result.repositoriesProbed, result.duration
        )))

        guard !result.proposals.isEmpty else {
            print("")
            print(Term.green("Nothing waiting. Everything you started is committed or pushed."))
            print("")
            return
        }

        let count = result.proposals.count
        print("")
        print(Term.bold("Pick up where you left off — \(count) thing\(count == 1 ? "" : "s"):"))
        print("")

        for proposal in result.proposals {
            printBrief(proposal)
        }

        if !dryRun {
            print(Term.dim("Open FlowTrace to keep or dismiss these."))
            print("")
        }
    }

    /// One entry, written to be recognised in a glance rather than measured.
    ///
    /// The filenames do the work: "IntentTrace.jsx, intent.js" tells you what this
    /// was in a way that "15 uncommitted files" never does.
    private func printBrief(_ proposal: ThreadProposal) {
        let e = proposal.evidence
        let days = e.daysSinceLastCommit

        print("  \(Term.bold(e.repositoryName))\(Term.dim(" · " + e.branch))"
              + Term.dim("   you stopped \(days)d ago"))

        if let was = e.sessionTitle {
            print("    \(Term.dim("was "))\(was)")
        }
        if let files = e.fileSummary {
            print("    \(Term.dim("editing "))\(Term.cyan(files))")
        }
        if let subject = e.lastCommitSubject {
            print("    \(Term.dim("last landed "))\(subject)")
        }

        var loose: [String] = []
        if e.dirtyFileCount > 0 { loose.append("\(e.dirtyFileCount) uncommitted") }
        if e.unpushedCommitCount > 0 { loose.append("\(e.unpushedCommitCount) unpushed") }
        if !loose.isEmpty {
            print("    \(Term.yellow(loose.joined(separator: " · ")))")
        }

        // The arc of what you were asking reads like a story; one line is a snapshot.
        if !e.promptArc.isEmpty {
            for prompt in e.promptArc {
                print("    \(Term.dim("· "))\(Term.dim(prompt))")
            }
        } else if let prompt = e.lastPrompt, !prompt.isEmpty {
            print("    \(Term.dim("· "))\(Term.dim(prompt))")
        }

        print("    \(Term.dim(e.repositoryPath.abbreviatingHome))")
        print("")
    }
}
