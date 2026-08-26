import Foundation

/// An append-only log for the things that are hard to observe from outside the
/// app: whether a global shortcut registered, whether it fired, whether the
/// panel took focus.
///
/// Written to a file rather than the console because the interesting events
/// happen while another app is frontmost, with no debugger attached.
public enum Diagnostics {
    public static var fileURL: URL {
        FlowTraceDatabase.supportDirectory.appendingPathComponent("debug.log")
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

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
