import Foundation

/// Minimal, non-interactive process runner.
///
/// Everything FlowTrace shells out to is read-only (`git` inspection commands).
/// stdin is closed and the environment is stripped of anything that could make
/// git prompt, so a probe can never hang waiting on a credential helper.
enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 5
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)")
        }

        // Drain concurrently: a probe on a large repo can fill the pipe buffer
        // and deadlock if we wait for exit before reading.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            return Result(status: -2, stdout: "", stderr: "timed out")
        }
        _ = group.wait(timeout: .now() + 2)

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
