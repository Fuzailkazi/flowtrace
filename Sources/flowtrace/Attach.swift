import Foundation
import ArgumentParser
import FlowTraceCore

/// Resolves a user-supplied thread reference: an id prefix, or a case-insensitive
/// title match.
func resolveThread(_ store: Store, query: String) throws -> WorkThread? {
    let threads = try store.allThreads()
    if let exact = threads.first(where: { $0.id == query }) { return exact }
    if let prefix = threads.first(where: { $0.id.hasPrefix(query) }) { return prefix }
    let needle = query.lowercased()
    return threads.first { $0.title.lowercased().contains(needle) }
}

struct Attach: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach the current repository or agent session to a work thread.",
        discussion: """
        Run this from inside a repository. FlowTrace records the repo, branch, \
        latest commit and how many files are uncommitted, alongside your note.
        """
    )

    @Option(name: .shortAndLong, help: "Thread to attach to — id prefix or part of the title.")
    var thread: String?

    @Option(name: .long, help: "Create a new thread with this title and attach to it.")
    var new: String?

    @Option(name: .shortAndLong, help: "Why does this matter? Stored with the capture.")
    var note: String = ""

    @Option(name: .long, help: "What should you do next here?")
    var nextStep: String = ""

    @Option(name: .customLong("agent"),
            help: "claude-code, cursor, opencode, codex, gemini-cli, other")
    var agentName: String?

    @Option(name: .long, help: "Repository path. Defaults to the current directory.")
    var path: String?

    func run() throws {
        let store = try openStore()
        let target = path ?? FileManager.default.currentDirectoryPath

        guard let state = GitProbe().probe(target) else {
            throw ValidationError("\(target) is not inside a git repository.")
        }

        let resolved = try resolveTarget(store)

        var context = CodeContext(
            agentName: agentName.flatMap { AgentName(rawValue: $0) },
            repositoryName: state.repositoryName,
            repositoryPath: state.topLevel,
            branch: state.branch,
            latestCommit: state.headSha,
            note: note,
            nextStep: nextStep,
            dirtyFileCount: state.dirtyFileCount,
            lastCommitAt: state.headDate,
            commitsAhead: state.commitsAhead,
            commitsBehind: state.commitsBehind
        )

        // Show what changed since this repo was last captured, if it has been.
        let change = try store.change(for: state.topLevel, against: state.snapshot())

        context = try store.attach(code: context, to: resolved.id)
        if !nextStep.isEmpty {
            var updated = resolved
            updated.nextStep = nextStep
            _ = try store.update(updated)
        }

        print("")
        print("  \(Term.green("✓")) \(Term.bold(state.repositoryName)) \(Term.dim("· " + state.branch)) → \(Term.bold(resolved.title))")
        if state.dirtyFileCount > 0 {
            print("    \(Term.yellow("\(state.dirtyFileCount) uncommitted file\(state.dirtyFileCount == 1 ? "" : "s")"))")
        }
        if let change, !change.isEmpty {
            print("    \(Term.dim("since last capture:")) \(change.summaryLines.joined(separator: ", "))")
        }
        print("    \(Term.dim(context.displayPath))")
        print("")
    }

    private func resolveTarget(_ store: Store) throws -> WorkThread {
        if let new {
            return try store.create(WorkThread(title: new, intent: note, nextStep: nextStep))
        }
        guard let thread else {
            let threads = try store.allThreads().filter { $0.status != .completed }
            guard !threads.isEmpty else {
                throw ValidationError(
                    "No work threads yet. Use --new \"Title\" to create one, or run `flowtrace scan`."
                )
            }
            let options = threads.prefix(10)
                .map { "  \($0.id.prefix(8))  \($0.title)" }
                .joined(separator: "\n")
            throw ValidationError("Pass --thread <id or title>. Open threads:\n\n\(options)\n")
        }
        guard let match = try resolveThread(store, query: thread) else {
            throw ValidationError("No thread matching \"\(thread)\".")
        }
        return match
    }
}
