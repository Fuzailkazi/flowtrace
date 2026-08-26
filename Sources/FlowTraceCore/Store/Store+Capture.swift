import Foundation
import GRDB

// Attaching captured context to threads: tabs, repositories, agent sessions, notes.
extension Store {
    // MARK: - Browser tabs

    /// Attaches captured tabs to a thread. Tabs are stored with title and URL
    /// only; nothing about page contents is ever read or kept.
    @discardableResult
    public func attach(tabs: [BrowserContext], to threadId: String?) throws -> [BrowserContext] {
        guard !tabs.isEmpty else { return [] }
        return try database.writer.write { db in
            var saved: [BrowserContext] = []
            for var tab in tabs {
                tab.workThreadId = threadId
                try tab.insert(db)
                saved.append(tab)
                if let threadId {
                    try SearchIndex.index(
                        db, kind: .tab, recordId: tab.id, threadId: threadId,
                        title: tab.pageTitle,
                        body: [tab.url, tab.note, tab.browser].filter { !$0.isEmpty }.joined(separator: " \n ")
                    )
                }
            }
            if let threadId {
                try Self.touch(db, threadId: threadId)
                try Self.record(db, TimelineEvent(
                    workThreadId: threadId,
                    type: .tabAttached,
                    title: saved.count == 1
                        ? "Attached a tab"
                        : "Attached \(saved.count) tabs",
                    description: saved.prefix(3).map(\.pageTitle).joined(separator: " · "),
                    metadata: ["count": String(saved.count)]
                ))
            }
            return saved
        }
    }

    public func removeTab(id: String) throws {
        try database.writer.write { db in
            guard let tab = try BrowserContext.fetchOne(db, key: id) else { return }
            try SearchIndex.remove(db, kind: .tab, recordId: id)
            _ = try BrowserContext.deleteOne(db, key: id)
            if let threadId = tab.workThreadId {
                try Self.record(db, TimelineEvent(
                    workThreadId: threadId, type: .tabRemoved,
                    title: "Removed a tab", description: tab.pageTitle
                ))
            }
        }
    }

    public func tabs(threadId: String) throws -> [BrowserContext] {
        try database.writer.read { db in
            try BrowserContext
                .filter(BrowserContext.Columns.workThreadId == threadId)
                .order(BrowserContext.Columns.capturedAt.desc)
                .fetchAll(db)
        }
    }

    public func recentTabs(limit: Int = 20) throws -> [BrowserContext] {
        try database.writer.read { db in
            try BrowserContext
                .order(BrowserContext.Columns.capturedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Which thread, if any, a URL is already filed under. Powers the extension badge.
    public func threadForURL(_ url: String) throws -> WorkThread? {
        try database.writer.read { db in
            guard let tab = try BrowserContext
                .filter(BrowserContext.Columns.url == url)
                .filter(BrowserContext.Columns.workThreadId != nil)
                .order(BrowserContext.Columns.capturedAt.desc)
                .fetchOne(db),
                let threadId = tab.workThreadId
            else { return nil }
            return try WorkThread.fetchOne(db, key: threadId)
        }
    }

    // MARK: - Code contexts

    @discardableResult
    public func attach(code: CodeContext, to threadId: String?) throws -> CodeContext {
        var code = code
        code.workThreadId = threadId
        code.repositoryPath = FilePathCanon.canonical(code.repositoryPath)
        return try database.writer.write { db in
            try code.insert(db)
            if let threadId {
                try SearchIndex.index(
                    db, kind: .code, recordId: code.id, threadId: threadId,
                    title: code.repositoryName,
                    body: [
                        code.repositoryPath, code.branch ?? "", code.note,
                        code.nextStep, code.agentName?.label ?? "",
                    ].filter { !$0.isEmpty }.joined(separator: " \n ")
                )
                try Self.touch(db, threadId: threadId)
                try Self.record(db, TimelineEvent(
                    workThreadId: threadId,
                    type: .codeAttached,
                    title: code.agentName.map { "Attached \($0.label) session" }
                        ?? "Attached repository",
                    description: "\(code.repositoryName)\(code.branch.map { " · \($0)" } ?? "")",
                    metadata: ["repository": code.repositoryPath, "branch": code.branch ?? ""]
                ))
            }
            // Snapshot git state so later visits can show what changed.
            var snapshot = RepoSnapshot(
                repositoryPath: code.repositoryPath,
                branch: code.branch ?? "",
                headSha: code.latestCommit,
                dirtyFileCount: code.dirtyFileCount,
                commitsAhead: code.commitsAhead,
                commitsBehind: code.commitsBehind,
                capturedAt: code.capturedAt
            )
            try snapshot.insert(db)
            return code
        }
    }

    public func removeCode(id: String) throws {
        try database.writer.write { db in
            guard let code = try CodeContext.fetchOne(db, key: id) else { return }
            try SearchIndex.remove(db, kind: .code, recordId: id)
            _ = try CodeContext.deleteOne(db, key: id)
            if let threadId = code.workThreadId {
                try Self.record(db, TimelineEvent(
                    workThreadId: threadId, type: .codeRemoved,
                    title: "Removed repository", description: code.repositoryName
                ))
            }
        }
    }

    public func codeContexts(threadId: String) throws -> [CodeContext] {
        try database.writer.read { db in
            try CodeContext
                .filter(CodeContext.Columns.workThreadId == threadId)
                .order(CodeContext.Columns.capturedAt.desc)
                .fetchAll(db)
        }
    }

    public func recentCodeContexts(limit: Int = 20) throws -> [CodeContext] {
        try database.writer.read { db in
            try CodeContext
                .order(CodeContext.Columns.capturedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Notes

    @discardableResult
    public func addNote(_ note: Note) throws -> Note {
        var note = note
        return try database.writer.write { db in
            try note.insert(db)
            try SearchIndex.index(
                db, kind: .note, recordId: note.id, threadId: note.workThreadId,
                title: note.isDecision ? "Decision" : "Note",
                body: note.content
            )
            try Self.touch(db, threadId: note.workThreadId)
            try Self.record(db, TimelineEvent(
                workThreadId: note.workThreadId,
                type: note.isDecision ? .decisionAdded : .noteAdded,
                title: note.isDecision ? "Decision recorded" : "Note added",
                description: String(note.content.prefix(200))
            ))
            return note
        }
    }

    public func notes(threadId: String) throws -> [Note] {
        try database.writer.read { db in
            try Note
                .filter(Note.Columns.workThreadId == threadId)
                .order(Note.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    public func deleteNote(id: String) throws {
        try database.writer.write { db in
            try SearchIndex.remove(db, kind: .note, recordId: id)
            _ = try Note.deleteOne(db, key: id)
        }
    }

    // MARK: - Repository change detection

    /// Compares the newest stored snapshot for a repository against a fresh probe,
    /// answering "what changed since I last worked on it?".
    public func change(for repositoryPath: String, against current: RepoSnapshot) throws -> RepoChange? {
        let canonical = FilePathCanon.canonical(repositoryPath)
        let previous = try database.writer.read { db in
            try RepoSnapshot
                .filter(RepoSnapshot.Columns.repositoryPath == canonical)
                .order(RepoSnapshot.Columns.capturedAt.desc)
                .fetchOne(db)
        }
        guard let previous else { return nil }
        let change = RepoChange.between(old: previous, new: current)
        return change.isEmpty ? nil : change
    }

    /// Bumps a thread's `updatedAt` when something is attached to it.
    static func touch(_ db: Database, threadId: String) throws {
        try db.execute(
            sql: "UPDATE workThread SET updatedAt = ? WHERE id = ?",
            arguments: [Date(), threadId]
        )
    }
}
