import Foundation

/// An append-only log for the things that are hard to observe from outside the
/// app: whether a global shortcut registered, whether it fired, whether the
/// panel took focus.
///
/// Written to a file rather than the console because the interesting events
/// happen while another app is frontmost, with no debugger attached.
public enum Diagnostics {
    /// Where the log lives. Injectable so tests that exercise the delete
    /// controls write to a scratch directory rather than removing the real one.
    public nonisolated(unsafe) static var directory: URL = FlowTraceDatabase.supportDirectory

    public static var fileURL: URL {
        directory.appendingPathComponent("debug.log")
    }

    private static let queue = DispatchQueue(label: "ai.flowtrace.diagnostics")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// How much the log is holding, for the holdings list.
    public static func sizeInBytes() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
    }

    /// Removes the log.
    ///
    /// The observable promise is "emptied or gone": `log` appends on its own
    /// queue, so a line written a moment after this can recreate the file.
    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
