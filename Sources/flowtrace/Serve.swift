import Foundation
import ArgumentParser
import FlowTraceCore

/// Runs the capture endpoint without the app — useful for headless setups, and
/// the quickest way to see why the endpoint won't start.
struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the local capture endpoint in the foreground."
    )

    @Option(name: .long, help: "Preferred port.")
    var port: UInt16 = 8787

    func run() throws {
        let store = try openStore()
        let server = LocalServer(store: store)
        server.onCapture = { print(Term.dim("  captured")) }

        try server.start(preferredPort: port)

        // The listener reports its port asynchronously once it is ready.
        var resolved: UInt16?
        for _ in 0..<50 where resolved == nil {
            Thread.sleep(forTimeInterval: 0.1)
            resolved = server.port
        }
        guard let resolved else {
            throw ValidationError("The endpoint did not become ready.")
        }

        print("")
        print("  \(Term.green("●")) listening on \(Term.bold("http://127.0.0.1:\(resolved)"))")
        print("  \(Term.dim("token:")) \(try LocalCredentials.token())")
        print("  \(Term.dim("Ctrl-C to stop"))")
        print("")
        dispatchMain()
    }
}
