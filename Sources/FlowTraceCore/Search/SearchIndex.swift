import Foundation
import GRDB

public enum SearchKind: String, Codable, Sendable {
    case thread, tab, code, note
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var kind: SearchKind
    public var recordId: String
    /// The thread this hit belongs to — always the navigation target.
    public var threadId: String
    public var title: String
    public var snippet: String
    public var rank: Double

    public var id: String { "\(kind.rawValue):\(recordId)" }
}

/// Full-text index across everything FlowTrace stores.
///
/// One denormalised FTS5 table rather than four external-content tables: the
/// sync is explicit, so the app and the CLI share a single code path and the
/// behaviour is directly testable.
public enum SearchIndex {
    static func index(
        _ db: Database,
        kind: SearchKind,
        recordId: String,
        threadId: String,
        title: String,
        body: String
    ) throws {
        try remove(db, kind: kind, recordId: recordId)
        try db.execute(
            sql: "INSERT INTO searchIndex (kind, recordId, threadId, title, body) VALUES (?, ?, ?, ?, ?)",
            arguments: [kind.rawValue, recordId, threadId, title, body]
        )
    }

    static func remove(_ db: Database, kind: SearchKind, recordId: String) throws {
        try db.execute(
            sql: "DELETE FROM searchIndex WHERE kind = ? AND recordId = ?",
            arguments: [kind.rawValue, recordId]
        )
    }

    static func removeAll(_ db: Database, threadId: String) throws {
        try db.execute(sql: "DELETE FROM searchIndex WHERE threadId = ?", arguments: [threadId])
    }

    // MARK: - Query

    /// Turn whatever the user typed into a valid FTS5 MATCH expression.
    ///
    /// Every token is quoted (so `blocked:` or `C++` can't be read as syntax) and
    /// given a prefix wildcard, which is what makes partial words like "auth" find
    /// "authentication".
    static func ftsExpression(for raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    public static func search(_ db: Database, query: String, limit: Int = 50) throws -> [SearchHit] {
        guard let expression = ftsExpression(for: query) else { return [] }

        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, recordId, threadId, title,
                   snippet(searchIndex, 4, '', '', '…', 14) AS snippet,
                   bm25(searchIndex, 0.0, 0.0, 0.0, 8.0, 2.0) AS rank
            FROM searchIndex
            WHERE searchIndex MATCH ?
            ORDER BY rank
            LIMIT ?
            """, arguments: [expression, limit])

        let hits = rows.compactMap { row -> SearchHit? in
            guard let kind = SearchKind(rawValue: row["kind"]) else { return nil }
            return SearchHit(
                kind: kind,
                recordId: row["recordId"],
                threadId: row["threadId"],
                title: row["title"],
                snippet: row["snippet"] ?? "",
                rank: row["rank"] ?? 0
            )
        }

        // A prefix match can still miss a substring in the middle of a word
        // ("code" inside "OpenCode"). Fall back rather than showing nothing.
        if hits.isEmpty {
            return try substringFallback(db, query: query, limit: limit)
        }
        return hits
    }

    private static func substringFallback(_ db: Database, query: String, limit: Int) throws -> [SearchHit] {
        let pattern = "%\(query.trimmingCharacters(in: .whitespaces))%"
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, recordId, threadId, title, body
            FROM searchIndex
            WHERE title LIKE ? OR body LIKE ?
            LIMIT ?
            """, arguments: [pattern, pattern, limit])

        return rows.compactMap { row -> SearchHit? in
            guard let kind = SearchKind(rawValue: row["kind"]) else { return nil }
            let body: String = row["body"] ?? ""
            return SearchHit(
                kind: kind,
                recordId: row["recordId"],
                threadId: row["threadId"],
                title: row["title"],
                snippet: String(body.prefix(140)),
                rank: 100
            )
        }
    }
}
