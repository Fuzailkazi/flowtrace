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

        print("")
        if let headline = state.headline {
            print("  \(Term.bold(headline))")
            print("")
        }

        for agent in state.agents {
            let mark = switch agent.state {
            case .working: Term.green("●")
            case .waiting: Term.yellow("●")
            case .idle:    Term.dim("○")
            }
            print("  \(mark) \(Term.bold(agent.repositoryName))"
                  + Term.dim("  \(agent.agent.label) · \(agent.lastActivityLabel)"))
            if let prompt = agent.lastPrompt {
                print("    \(Term.dim(prompt))")
            }
        }

        if !state.servers.isEmpty {
            print("")
            print("  \(Term.bold("\(state.servers.count) server\(state.servers.count == 1 ? "" : "s") listening"))")
            for server in state.servers {
                print("  \(Term.cyan(":\(server.port)"))"
                      + Term.dim("  \(server.processName) · \(server.projectName ?? "")"))
            }
        }
        print("")
    }
}
