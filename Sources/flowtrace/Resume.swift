import Foundation
import ArgumentParser
import FlowTraceCore

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print everything you need to pick a thread back up, and mark it resumed."
    )

    @Argument(help: "Thread to resume — id prefix or part of the title.")
    var thread: String

    @Flag(name: .long, help: "Show the context without marking the thread resumed.")
    var peek = false

    @Flag(name: .long, help: "Also open FlowTrace on this thread.")
    var open = false

    func run() throws {
        let store = try openStore()
        guard let match = try resolveThread(store, query: thread) else {
            throw ValidationError("No thread matching \"\(thread)\".")
        }

        let resolved = peek ? match : (try store.resume(threadId: match.id) ?? match)
        let tabs = try store.tabs(threadId: resolved.id)
        let code = try store.codeContexts(threadId: resolved.id)
        let notes = try store.notes(threadId: resolved.id)

        print("")
        print("  \(Term.bold(resolved.title))  \(Term.dim(resolved.status.label.lowercased()))")
        if !resolved.intent.isEmpty {
            print("  \(Term.dim("why:"))  \(resolved.intent)")
        }
        if !resolved.nextStep.isEmpty {
            print("  \(Term.cyan("next:")) \(resolved.nextStep)")
        }
        if let blocker = resolved.blocker, !blocker.isEmpty {
            print("  \(Term.red("blocked:")) \(blocker)")
        }

        if !code.isEmpty {
            print("")
            print("  \(Term.dim("repositories"))")
            for item in code {
                let git = GitProbe().probe(item.repositoryPath)
                var line = "    \(item.repositoryName)"
                if let branch = git?.branch ?? item.branch { line += Term.dim(" · \(branch)") }
                if let git, git.dirtyFileCount > 0 {
                    line += "  " + Term.yellow("\(git.dirtyFileCount) uncommitted")
                }
                print(line)
                if !item.note.isEmpty { print("      \(Term.dim(item.note))") }
            }
        }

        if !tabs.isEmpty {
            print("")
            print("  \(Term.dim("tabs"))")
            for tab in tabs.prefix(12) {
                print("    \(tab.pageTitle)  \(Term.dim(tab.host))")
                if !tab.note.isEmpty { print("      \(Term.dim(tab.note))") }
            }
        }

        if let latest = notes.first {
            print("")
            print("  \(Term.dim("latest note"))")
            print("    \(latest.content.prefix(280))")
        }

        print("")
        if !peek { print(Term.dim("  Marked resumed.")) ; print("") }

        if open { openApp(threadId: resolved.id) }
    }

    /// Launches (or re-activates) FlowTrace with this thread selected.
    private func openApp(threadId: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "FlowTrace", "--env", "FLOWTRACE_OPEN_THREAD=\(threadId)"]
        try? process.run()
        process.waitUntilExit()
    }
}
