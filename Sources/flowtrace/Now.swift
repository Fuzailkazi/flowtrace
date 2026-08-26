import Foundation
import ArgumentParser
import FlowTraceCore

/// What is happening on this machine right now.
struct Now: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the agents and servers running right now."
    )

    func run() throws {
        let state = LiveStateReader().read()
        let notes = (try? openStore().allProjectNotes()) ?? []
        let byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.repositoryPath, $0) })
        let projects = state.projects(notes: byPath)

        print("")
        let live = projects.filter { $0.agents.contains { $0.state != .idle } }.count
        print("  \(Term.bold("\(projects.count) place\(projects.count == 1 ? "" : "s")"))"
              + Term.dim("  \(state.agents.count) agents · \(state.servers.count) servers"
                         + (live > 0 ? " · \(live) active" : "")))
        print("")

        for project in projects {
            let mark = project.agents.contains { $0.state == .working } ? Term.green("●")
                     : project.agents.contains { $0.state == .waiting } ? Term.cyan("●")
                     : Term.dim("○")

            print("  \(mark) \(Term.bold(project.name))"
                  + Term.dim("   \(project.statusLabel)"))

            if let note = project.note, !note.building.isEmpty {
                print("    \(Term.cyan(note.building))")
            }
            if let prompt = project.lastPrompt {
                print("    \(Term.dim(prompt))")
            }
            if !project.servers.isEmpty {
                let ports = project.servers.map { ":\($0.port)" }.joined(separator: " ")
                print("    \(Term.dim("listening"))  \(Term.cyan(ports))")
            }
            print("")
        }
    }
}
