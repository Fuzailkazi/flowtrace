import Foundation

/// Streams a file line by line without loading it into memory.
///
/// Session transcripts can reach tens of megabytes; a scan touches hundreds of
/// them, so reading whole files would dominate the scan budget.
struct LineReader: Sequence, IteratorProtocol {
    private let handle: FileHandle
    private let chunkSize: Int
    private var buffer = Data()
    private var reachedEOF = false
    private static let newline = UInt8(ascii: "\n")

    init?(path: String, chunkSize: Int = 1 << 16) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
        self.chunkSize = chunkSize
    }

    mutating func next() -> String? {
        while true {
            if let index = buffer.firstIndex(of: Self.newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                return String(decoding: lineData, as: UTF8.self)
            }
            if reachedEOF {
                defer { buffer.removeAll() }
                guard !buffer.isEmpty else {
                    try? handle.close()
                    return nil
                }
                return String(decoding: buffer, as: UTF8.self)
            }
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                reachedEOF = true
            }
        }
    }
}

enum FileMeta {
    static func stat(_ path: String) -> (size: Int64, modifiedAt: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64,
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return nil }
        return (size, modifiedAt)
    }
}
