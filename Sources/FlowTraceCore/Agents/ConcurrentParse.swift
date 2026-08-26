import Foundation

/// Parses a batch of session files in parallel.
///
/// A first scan reads hundreds of transcripts and that is where nearly all of
/// its time goes; on this machine parallelising took a cold scan from 7.5s to
/// 3.5s. Adapters share this rather than each rolling their own.
enum ConcurrentParse {
    static func sessions(
        in paths: [String],
        _ parse: @escaping (String) -> AgentSession?
    ) -> [AgentSession] {
        guard !paths.isEmpty else { return [] }

        var results: [AgentSession] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let session = parse(paths[index]) else { return }
            lock.lock()
            results.append(session)
            lock.unlock()
        }
        return results
    }
}
