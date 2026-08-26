import Foundation
import ArgumentParser
import FlowTraceCore

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List your work threads.")

    @Option(name: .long, help: "Filter by status: active, paused, completed.")
    var status: String?

    func run() throws {
        let store = try openStore()
        let threads: [WorkThread]
        if let status, let parsed = ThreadStatus(rawValue: status.lowercased()) {
            threads = try store.threads(status: parsed)
        } else {
            threads = try store.allThreads()
        }

        guard !threads.isEmpty else {
            print(Term.dim("No work threads yet. Run `flowtrace scan` to find unfinished work."))
            return
        }

        print("")
        for thread in threads {
            let marker = thread.isBlocked ? Term.red("●") : Term.green("●")
            print("  \(marker) \(Term.bold(thread.title))  \(Term.dim(thread.status.label.lowercased()))")
            if !thread.nextStep.isEmpty {
                print("    \(Term.dim("next:")) \(thread.nextStep)")
            }
            if let blocker = thread.blocker, !blocker.isEmpty {
                print("    \(Term.red("blocked:")) \(blocker)")
            }
            print("    \(Term.dim(Term.relative(thread.lastActivityAt) + " · " + thread.id.prefix(8)))")
            print("")
        }
    }
}
