import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A deliberately narrow stop operation for processes FlowTrace discovered as
/// local development servers. It never accepts a process name or a shell
/// command from the UI: the reviewed PID and its current executable identity
/// are checked again immediately before signalling.
public actor ProcessStopper {
    public enum Outcome: Equatable, Sendable {
        case stopped
        case unavailable
        case identityChanged
        case failed(String)
    }

    private let signal: @Sendable (Int32, Int32) -> Bool
    private let executablePath: @Sendable (Int32) -> String?

    public init(
        signal: @escaping @Sendable (Int32, Int32) -> Bool = { pid, value in
            #if canImport(Darwin)
            return kill(pid, value) == 0
            #else
            return false
            #endif
        },
        executablePath: @escaping @Sendable (Int32) -> String? = { pid in
            #if canImport(Darwin)
            var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(cString: buffer)
            #else
            return nil
            #endif
        }
    ) {
        self.signal = signal
        self.executablePath = executablePath
    }

    /// Pure identity rule, exposed so the safety boundary can be tested without
    /// touching a real process table.
    public static func identityMatches(server: LiveServer, executablePath: String) -> Bool {
        URL(fileURLWithPath: executablePath).lastPathComponent == server.processName
    }

    /// Stops only when the process still has the executable identity captured
    /// in the review. A second verification prevents a reused PID from ever
    /// receiving the signal intended for the old server.
    public func stop(server: LiveServer) -> Outcome {
        guard server.pid > 0, let current = executablePath(server.pid) else {
            return .unavailable
        }
        guard Self.identityMatches(server: server, executablePath: current)
        else { return .identityChanged }
        guard signal(server.pid, SIGTERM) else { return .failed("The process could not be stopped.") }
        return .stopped
    }
}
