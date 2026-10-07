import Foundation

/// Keeps a recorder write and its stop decision in one critical section.
/// An old run's queued work stays invalid after recording starts again.
final class RecorderWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    func start() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        active = true
        return generation
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        generation &+= 1
    }

    @discardableResult
    func performIfCurrent(_ token: UInt64, _ action: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, token == generation else { return false }
        try action()
        return true
    }
}
