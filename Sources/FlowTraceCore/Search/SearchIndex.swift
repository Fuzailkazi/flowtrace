import Foundation
import GRDB

public enum SearchKind: String, Codable, Sendable {
    case thread, tab, code, note, screenshot
    /// A note the user wrote on something they were doing. What the Memories
    /// screen shows, and the thing people mean when they say "my notes".
    case memory
    /// What the user said they were building in a project.
    case place

    /// Whether the hit belongs to a work thread. The kinds that do navigate by
    /// `threadId`; the kinds that do not navigate by `recordId`, which is an
    /// activity id for a memory and a repository path for a place.
    public var navigatesByThread: Bool {
        switch self {
        case .thread, .tab, .code, .note: true
        case .memory, .place, .screenshot: false
        }
    }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public enum MatchQuality: Hashable, Sendable {
        case allTerms, partial, substring
    }

    public var kind: SearchKind
    public var recordId: String
    /// The thread this hit belongs to — always the navigation target.
    public var threadId: String
    public var title: String
    public var snippet: String
    public var rank: Double
    /// A result from the broader fallback must be labelled, so the user does
    /// not mistake one matching word for an answer to the whole question.
    public var matchQuality: MatchQuality

    public var id: String { "\(kind.rawValue):\(recordId)" }
}

/// Full-text index across everything FlowTrace stores.
///
/// One denormalised FTS5 table rather than four external-content tables: the
/// sync is explicit, so the app and the CLI share a single code path and the
/// behaviour is directly testable.
public enum SearchIndex {
    private static let fillerWords: Set<String> = [
        "a", "an", "and", "are", "at", "did", "do", "for", "from", "i",
        "in", "is", "it", "me", "my", "of", "on", "or", "that", "the",
        "this", "to", "was", "were", "what", "when", "where", "with",
    ]

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

    /// Filler words in a spoken question should not prevent its actual subject
    /// from being found. If every word is filler, keep the original terms.
    private static func searchTerms(in raw: String) -> [String] {
        let words = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let meaningful = words.filter { !fillerWords.contains($0.lowercased()) }
        var seen = Set<String>()
        return (meaningful.isEmpty ? words : meaningful).filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    private static func ftsExpression(tokens: [String], joiningWith separator: String) -> String {
        // Quote each token so punctuation and search operators are never syntax.
        tokens.map { "\"\($0)\"*" }.joined(separator: separator)
    }

    public static func search(_ db: Database, query: String, limit: Int = 50) throws -> [SearchHit] {
        try search(db, query: query, limit: limit, onlyMemories: false)
    }

    /// The Memories screen has its own result budget. Legacy thread and tab
    /// records cannot crowd a matching personal note out of that budget.
    public static func searchMemories(_ db: Database, query: String, limit: Int = 200) throws -> [SearchHit] {
        try search(db, query: query, limit: limit, onlyMemories: true)
    }

    public static func searchScreenshots(_ db: Database, query: String, limit: Int = 50) throws -> [SearchHit] {
        try search(db, query: query, limit: limit, onlyMemories: false, onlyScreenshots: true)
    }

    private static func search(
        _ db: Database, query: String, limit: Int, onlyMemories: Bool, onlyScreenshots: Bool = false
    ) throws -> [SearchHit] {
        let terms = searchTerms(in: query)
        guard !terms.isEmpty else { return [] }
        let scope = onlyScreenshots ? "AND kind = 'screenshot'" : (onlyMemories ? "AND kind IN ('memory', 'place')" : "")

        let complete = try rankedMatches(
            db, expression: ftsExpression(tokens: terms, joiningWith: " AND "),
            scope: scope, limit: limit, quality: .allTerms
        )
        if !complete.isEmpty { return complete }

        // A real person often adds a remembered detail that was never saved.
        // Return something useful, but mark it as a partial answer in the UI.
        if terms.count > 1 {
            let partial = try rankedMatches(
                db, expression: ftsExpression(tokens: terms, joiningWith: " OR "),
                scope: scope, limit: limit, quality: .partial
            )
            if !partial.isEmpty { return partial }
        }

        // A prefix match can still miss a substring inside one word ("code"
        // inside "OpenCode"). Try the literal phrase as a last resort.
        return try substringFallback(db, query: query, limit: limit, scope: scope)
    }

    private static func rankedMatches(
        _ db: Database, expression: String, scope: String, limit: Int,
        quality: SearchHit.MatchQuality
    ) throws -> [SearchHit] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, recordId, threadId, title,
                   snippet(searchIndex, 4, '', '', '…', 14) AS snippet,
                   bm25(searchIndex, 0.0, 0.0, 0.0, 8.0, 2.0) AS rank
            FROM searchIndex
            WHERE searchIndex MATCH ?
            \(scope)
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
                rank: row["rank"] ?? 0,
                matchQuality: quality
            )
        }
        return hits
    }

    private static func substringFallback(
        _ db: Database, query: String, limit: Int, scope: String
    ) throws -> [SearchHit] {
        let literal = query.trimmingCharacters(in: .whitespaces)
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, recordId, threadId, title, body
            FROM searchIndex
            WHERE (instr(lower(title), lower(?)) > 0 OR instr(lower(body), lower(?)) > 0)
            \(scope)
            LIMIT ?
            """, arguments: [literal, literal, limit])

        return rows.compactMap { row -> SearchHit? in
            guard let kind = SearchKind(rawValue: row["kind"]) else { return nil }
            let body: String = row["body"] ?? ""
            return SearchHit(
                kind: kind,
                recordId: row["recordId"],
                threadId: row["threadId"],
                title: row["title"],
                snippet: String(body.prefix(140)),
                rank: 100,
                matchQuality: .substring
            )
        }
    }
}
