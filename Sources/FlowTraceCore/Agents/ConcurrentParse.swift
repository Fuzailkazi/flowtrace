import Foundation

/// Parses a batch of session files in parallel.
///
/// A first scan reads hundreds of transcripts and that is where nearly all of
/// its time goes; on this machine parallelising took a cold scan from 7.5s to
/// 3.5s. Adapters share this rather than each rolling their own.
enum ConcurrentParse {
    struct Report {
        var sessions: [AgentSession]
        var skippedFiles: Int
    }

    static func sessions(
        in paths: [String],
        _ parse: @escaping (String) -> AgentSession?
    ) -> [AgentSession] {
        report(in: paths, parse).sessions
    }

    static func report(
        in paths: [String],
        _ parse: @escaping (String) -> AgentSession?
    ) -> Report {
        guard !paths.isEmpty else { return Report(sessions: [], skippedFiles: 0) }

        var results: [AgentSession] = []
        var skipped = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let session = parse(paths[index]) else {
                lock.lock()
                skipped += 1
                lock.unlock()
                return
            }
            lock.lock()
            results.append(session)
            lock.unlock()
        }
        return Report(sessions: results, skippedFiles: skipped)
    }
}
