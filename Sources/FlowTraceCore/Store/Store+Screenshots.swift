import Foundation
import GRDB

public enum ScreenshotOCRStatus: String, Codable, Sendable {
    case pending, succeeded, failed
}

public struct ScreenshotMetadata: Identifiable, Sendable {
    public let id: String
    public let importedAt: Date
    public let description: String
    public let ocrText: String
    public let ocrStatus: ScreenshotOCRStatus
    public let imageMIMEType: String
    public let thumbnailData: Data
}

public struct ScreenshotMemory: Identifiable, Sendable {
    public let id: String
    public let importedAt: Date
    public let description: String
    public let ocrText: String
    public let ocrStatus: ScreenshotOCRStatus
    public let imageMIMEType: String
    public let thumbnailData: Data
    public let imageData: Data
}

public enum ScreenshotStoreError: Error, LocalizedError {
    case invalidImage
    case imageTooLarge
    case thumbnailTooLarge
    case invalidOCRStatus

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "The processed JPEG or thumbnail is empty."
        case .imageTooLarge: "The processed JPEG exceeds 10 MB."
        case .thumbnailTooLarge: "The screenshot thumbnail exceeds 128 KB."
        case .invalidOCRStatus: "The screenshot has an unrecognized OCR status."
        }
    }
}

extension Store {
    private static let metadataColumns = "id, importedAt, description, ocrText, ocrStatus, imageMIMEType, thumbnailData"

    @discardableResult
    public func createScreenshot(
        imageData: Data,
        thumbnailData: Data,
        description: String = "",
        ocrText: String = "",
        ocrStatus: ScreenshotOCRStatus = .pending,
        importedAt: Date = Date()
    ) throws -> ScreenshotMemory {
        guard !imageData.isEmpty, !thumbnailData.isEmpty else { throw ScreenshotStoreError.invalidImage }
        guard imageData.count <= 10_000_000 else { throw ScreenshotStoreError.imageTooLarge }
        guard thumbnailData.count <= 128_000 else { throw ScreenshotStoreError.thumbnailTooLarge }
        let id = UUID().uuidString
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO screenshotMemory
                    (id, importedAt, description, ocrText, ocrStatus, imageMIMEType, thumbnailData, imageData)
                VALUES (?, ?, ?, ?, ?, 'image/jpeg', ?, ?)
                """, arguments: [id, importedAt, description, ocrText, ocrStatus.rawValue, thumbnailData, imageData])
            try Self.reindexScreenshot(db, id: id, description: description, ocrText: ocrText)
        }
        return ScreenshotMemory(id: id, importedAt: importedAt, description: description,
                                ocrText: ocrText, ocrStatus: ocrStatus, imageMIMEType: "image/jpeg",
                                thumbnailData: thumbnailData, imageData: imageData)
    }

    public func screenshots(limit: Int = 50, offset: Int = 0) throws -> [ScreenshotMetadata] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.metadataColumns) FROM screenshotMemory
                ORDER BY importedAt DESC, id DESC LIMIT ? OFFSET ?
                """, arguments: [max(0, limit), max(0, offset)]).map { try Self.metadata($0) }
        }
    }

    public func screenshot(id: String) throws -> ScreenshotMemory? {
        try database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM screenshotMemory WHERE id = ?", arguments: [id]) else { return nil }
            let info = try Self.metadata(row)
            return ScreenshotMemory(id: info.id, importedAt: info.importedAt,
                                    description: info.description, ocrText: info.ocrText,
                                    ocrStatus: info.ocrStatus, imageMIMEType: info.imageMIMEType,
                                    thumbnailData: info.thumbnailData, imageData: row["imageData"])
        }
    }

    public func searchScreenshots(query: String, limit: Int = 50, offset: Int = 0) throws -> [ScreenshotMetadata] {
        let pageLimit = max(0, limit)
        let pageOffset = max(0, offset)
        guard pageLimit > 0 else { return [] }
        let (sum, overflow) = pageLimit.addingReportingOverflow(pageOffset)
        let searchLimit = overflow ? Int.max : sum
        return try database.writer.read { db in
            let ids = try SearchIndex.searchScreenshots(db, query: query, limit: searchLimit)
                .map(\.recordId)
            let page = ids.dropFirst(pageOffset).prefix(pageLimit)
            return try page.compactMap { id in
                try Row.fetchOne(db, sql: "SELECT \(Self.metadataColumns) FROM screenshotMemory WHERE id = ?", arguments: [id]).map { try Self.metadata($0) }
            }
        }
    }

    public func updateScreenshotDescription(id: String, description: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE screenshotMemory SET description = ? WHERE id = ?", arguments: [description, id])
            try Self.reindexExistingScreenshot(db, id: id)
        }
    }

    public func updateScreenshotOCR(id: String, text: String, status: ScreenshotOCRStatus) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE screenshotMemory SET ocrText = ?, ocrStatus = ? WHERE id = ?",
                           arguments: [text, status.rawValue, id])
            try Self.reindexExistingScreenshot(db, id: id)
        }
    }

    public func deleteScreenshot(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM screenshotMemory WHERE id = ?", arguments: [id])
            try SearchIndex.remove(db, kind: .screenshot, recordId: id)
        }
    }

    public func screenshotCount() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshotMemory") ?? 0
        }
    }

    private static func metadata(_ row: Row) throws -> ScreenshotMetadata {
        let rawStatus: String = row["ocrStatus"]
        guard let status = ScreenshotOCRStatus(rawValue: rawStatus) else { throw ScreenshotStoreError.invalidOCRStatus }
        return ScreenshotMetadata(id: row["id"], importedAt: row["importedAt"],
                           description: row["description"], ocrText: row["ocrText"],
                           ocrStatus: status,
                           imageMIMEType: row["imageMIMEType"], thumbnailData: row["thumbnailData"])
    }

    private static func reindexExistingScreenshot(_ db: Database, id: String) throws {
        guard let row = try Row.fetchOne(db, sql: "SELECT description, ocrText FROM screenshotMemory WHERE id = ?", arguments: [id]) else { return }
        try reindexScreenshot(db, id: id, description: row["description"], ocrText: row["ocrText"])
    }

    private static func reindexScreenshot(_ db: Database, id: String, description: String, ocrText: String) throws {
        try SearchIndex.index(db, kind: .screenshot, recordId: id, threadId: "",
                              title: description.isEmpty ? "Screenshot" : description,
                              body: ocrText)
    }
}
