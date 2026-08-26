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
        if result.missingPaths > 0 {
            print(Term.dim("\(result.missingPaths) working directories no longer exist on disk."))
        }

        guard !result.proposals.isEmpty else {
            print("")
            print(Term.green("Nothing abandoned. Everything you started is committed or pushed."))
            print("")
            return
        }

        let count = result.proposals.count
        print("")
        print(Term.bold("\(count) piece\(count == 1 ? "" : "s") of unfinished work:"))
        print("")

        for proposal in result.proposals {
            let evidence = proposal.evidence
            let heat = evidence.daysSinceLastCommit >= 30 ? Term.red : Term.yellow

            print("  \(Term.bold(proposal.suggestedTitle))")
            print("  \(Term.cyan(evidence.repositoryName))\(Term.dim(" · " + evidence.branch))  "
                  + heat(evidence.reasons.joined(separator: "  ·  ")))
            if let prompt = evidence.lastPrompt, !prompt.isEmpty {
                print("  \(Term.dim("last asked:")) \(prompt)")
            }
            print("  \(Term.dim(evidence.repositoryPath.abbreviatingHome))")
            print("")
        }

        if !dryRun {
            print(Term.dim("Stored as proposals. Open FlowTrace to confirm or dismiss them."))
            print("")
        }
    }

}
