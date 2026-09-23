import Foundation
import FlowTraceCore

func runProcessStopperTests() {
    TestKit.suite("Safe background stopping")

    let server = LiveServer(
        pid: 4123, port: 3000, processName: "node",
        workingDirectory: "/Users/dev/app", projectRoot: "/Users/dev/app",
        projectName: "app"
    )

    TestKit.test("same executable identity is eligible") {
        expect(ProcessStopper.identityMatches(server: server, executablePath: "/usr/local/bin/node"))
    }

    TestKit.test("a reused PID with a different executable is refused") {
        expect(!ProcessStopper.identityMatches(server: server, executablePath: "/usr/bin/python3"))
    }

    TestKit.test("path matching uses the executable name, not a working directory") {
        expect(ProcessStopper.identityMatches(server: server, executablePath: "/tmp/node"))
        expect(!ProcessStopper.identityMatches(server: server, executablePath: "/Users/dev/app/node-project"))
    }
}
