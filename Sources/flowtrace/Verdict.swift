import Foundation
import ArgumentParser
import FlowTraceCore

/// Records whether the brief actually beat typing it yourself.
///
/// This is the whole experiment. The riskiest assumption in FlowTrace is not
/// privacy or feasibility — it is that an auto-generated brief is better than the
/// thirty seconds a developer already spends saying "we were fixing the auth
/// redirect, continue". Claude Code ships `/resume` and full transcripts; the
/// brief has to beat the free thing already in the box, not merely exist.
struct Verdict: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record whether the last brief beat what you'd have typed.",
        discussion: """
        Run `flowtrace verdict win` or `loss` after a session that opened with a \
        brief. Read the tally with `--report`. The agreed kill criterion is fewer \
        than 4 wins in 7 days.
        """
    )

    @Argument(help: "win or loss")
    var judgement: String?

    @Option(name: .long, help: "Why — a few words for your later self.")
    var note: String?

    @Flag(name: .long, help: "Show the tally instead of recording one.")
    var report = false

    func run() throws {
        let store = try openStore()
        if report || judgement == nil {
            try printReport(store)
            return
        }

        guard let parsed = BriefLogEntry.Verdict(rawValue: judgement!.lowercased()) else {
            throw ValidationError("Say `win` or `loss`.")
        }
        guard let entry = try store.judgeLatestBrief(parsed, note: note) else {
            throw ValidationError(
                "No brief is waiting to be judged. Briefs are recorded when they're shown."
            )
        }

        let mark = parsed == .win ? Term.green("✓ win") : Term.yellow("· loss")
        print("")
        print("  \(mark)  \(Term.bold(entry.repositoryName))  \(Term.dim(Term.relative(entry.shownAt)))")
        print("")
    }

    private func printReport(_ store: Store) throws {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let entries = try store.briefLog(since: weekAgo)

        guard !entries.isEmpty else {
            print("")
            print(Term.dim("No briefs shown in the last 7 days."))
            print(Term.dim("Install the hook with ./Scripts/install-hook.sh, then use Claude Code normally."))
            print("")
            return
        }

        let judged = entries.filter { $0.verdict != nil }
        let wins = judged.filter { $0.verdict == .win }.count
        let losses = judged.count - wins

        // Distinct days matter more than raw count: seven briefs in one morning
        // is one day of evidence, not seven.
        let days = Set(entries.map { Calendar.current.startOfDay(for: $0.shownAt) }).count
        let averageTokens = entries.map(\.estimatedTokens).reduce(0, +) / max(1, entries.count)

        print("")
        print(Term.bold("Last 7 days"))
        print("  \(entries.count) brief\(entries.count == 1 ? "" : "s") shown across \(days) day\(days == 1 ? "" : "s")")
        print("  \(Term.green("\(wins) win"))\(wins == 1 ? "" : "s") · \(losses) loss\(losses == 1 ? "" : "es") · \(entries.count - judged.count) unjudged")
        print("  \(Term.dim("~\(averageTokens) tokens per brief"))")
        print("")

        // The criterion was set before the data existed, which is the only way a
        // kill criterion means anything.
        if wins >= 4 {
            print("  \(Term.green("Passes"))  4+ wins. The brief is worth building on.")
        } else if judged.count >= 7 {
            print("  \(Term.red("Fails"))  under 4 wins in 7 judged. Don't build the capture layer.")
        } else {
            print("  \(Term.dim("Undecided — \(max(0, 7 - judged.count)) more judgements to call it."))")
        }
        print("")

        for entry in entries.prefix(10) {
            let mark = switch entry.verdict {
            case .win: Term.green("✓")
            case .loss: Term.yellow("·")
            case nil: Term.dim("?")
            }
            var line = "  \(mark) \(entry.repositoryName)"
            if let note = entry.note, !note.isEmpty { line += Term.dim("  \(note)") }
            print(line + Term.dim("  \(Term.relative(entry.shownAt))"))
        }
        print("")
    }
}
