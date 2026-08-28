import Foundation
import GRDB

/// Scan memo backed by the database, so a rescan only re-parses files that
/// changed since last time.
public final class StoreSessionCache: SessionCache {
    private let store: Store
    private var pending: [ScanCacheEntry] = []
    /// Session files are parsed concurrently during a scan.
    private let lock = NSLock()
    private var memo: [String: ScanCacheEntry] = [:]

    public init(store: Store) {
        self.store = store
        // One read beats a query per file: a full scan touches hundreds.
        memo = (try? store.allCacheEntries()) ?? [:]
    }

    public func cached(path: String, size: Int64, modifiedAt: Date) -> AgentSession? {
        lock.lock()
        let entry = memo[path]
        lock.unlock()
        guard let entry,
              entry.fileSize == size,
              abs(entry.modifiedAt.timeIntervalSince(modifiedAt)) < 1,
              let data = entry.payload.data(using: .utf8),
              let session = try? JSONDecoder().decode(AgentSession.self, from: data)
        else { return nil }
        return session
    }

    public func store(_ session: AgentSession, path: String, size: Int64, modifiedAt: Date) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let entry = ScanCacheEntry(
            filePath: path,
            fileSize: size,
            modifiedAt: modifiedAt,
            payload: String(decoding: data, as: UTF8.self)
        )
        lock.lock()
        pending.append(entry)
        memo[path] = entry
        lock.unlock()
    }

    /// Writes buffered entries in one transaction. Call after a scan completes.
    public func flush() {
        lock.lock()
        let batch = pending
        pending = []
        lock.unlock()
        guard !batch.isEmpty else { return }
        try? store.saveCacheEntries(batch)
    }
}

extension Store {
    func allCacheEntries() throws -> [String: ScanCacheEntry] {
        try database.writer.read { db in
            Dictionary(
                uniqueKeysWithValues: try ScanCacheEntry.fetchAll(db).map { ($0.filePath, $0) }
            )
        }
    }

    func saveCacheEntries(_ entries: [ScanCacheEntry]) throws {
        try database.writer.write { db in
            for entry in entries { try entry.save(db) }
        }
    }

    // MARK: - Proposals

    /// Merges a fresh scan into stored proposals.
    ///
    /// Dismissed proposals stay dismissed and accepted ones stay accepted, so a
    /// rescan never re-offers something the user already ruled on.
    @discardableResult
    public func mergeProposals(_ scanned: [ThreadProposal]) throws -> [ThreadProposal] {
        try database.writer.write { db in
            let existing = try ThreadProposal.fetchAll(db)
            var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.dedupeKey, $0) })

            for var incoming in scanned {
                if var current = byKey[incoming.dedupeKey] {
                    // Refresh evidence and score, preserve the user's decision.
                    current.score = incoming.score
                    current.evidence = incoming.evidence
                    current.suggestedTitle = incoming.suggestedTitle
                    current.suggestedIntent = incoming.suggestedIntent
                    current.suggestedNextStep = incoming.suggestedNextStep
                    current.lastSeenAt = Date()
                    try current.update(db)
                    byKey[current.dedupeKey] = current
                } else {
                    try incoming.insert(db)
                    byKey[incoming.dedupeKey] = incoming
                }
            }

            return try ThreadProposal
                .filter(ThreadProposal.Columns.state == ProposalState.pending.rawValue)
                .order(ThreadProposal.Columns.score.desc)
                .fetchAll(db)
        }
    }

    public func pendingProposals() throws -> [ThreadProposal] {
        try database.writer.read { db in
            try ThreadProposal
                .filter(ThreadProposal.Columns.state == ProposalState.pending.rawValue)
                .order(ThreadProposal.Columns.score.desc)
                .fetchAll(db)
        }
    }

    /// Turns a confirmed proposal into a real thread with its repository attached
    /// and its evidence written into the timeline.
    ///
    /// `edited` carries whatever the user changed in the review step — the
    /// proposal is a suggestion, and what gets stored is what they approved.
    @discardableResult
    public func accept(
        proposal: ThreadProposal,
        edited: (title: String, intent: String, nextStep: String)? = nil,
        priority: Priority = .medium
    ) throws -> WorkThread {
        let thread = WorkThread(
            title: edited?.title ?? proposal.suggestedTitle,
            description: "",
            intent: edited?.intent ?? proposal.suggestedIntent,
            nextStep: edited?.nextStep ?? proposal.suggestedNextStep,
            status: .active,
            priority: priority,
            origin: .detected,
            detectionEvidence: proposal.evidence
        )
        let created = try create(thread)

        let evidence = proposal.evidence
        try attach(
            code: CodeContext(
                agentName: evidence.agents.first,
                repositoryName: evidence.repositoryName,
                repositoryPath: evidence.repositoryPath,
                branch: evidence.branch,
                note: evidence.reasons.joined(separator: " · "),
                nextStep: created.nextStep,
                dirtyFileCount: evidence.dirtyFileCount
            ),
            to: created.id
        )

        try database.writer.write { db in
            var updated = proposal
            updated.state = .accepted
            updated.acceptedThreadId = created.id
            try updated.update(db)
        }
        return created
    }

    public func dismiss(proposal: ThreadProposal, ignorePathEntirely: Bool = false) throws {
        try database.writer.write { db in
            var updated = proposal
            updated.state = .dismissed
            try updated.update(db)
            if ignorePathEntirely {
                try IgnoredPath(
                    path: FilePathCanon.canonical(proposal.repositoryPath),
                    reason: "dismissed"
                ).save(db)
            }
        }
    }

    public func ignoredPaths() throws -> Set<String> {
        try database.writer.read { db in
            Set(try IgnoredPath.fetchAll(db).map(\.path))
        }
    }
}

extension Store {
    /// Removes a repository from the ignore list so it can be proposed again.
    public func stopIgnoring(path: String) throws {
        _ = try database.writer.write { db in
            try IgnoredPath.deleteOne(db, key: FilePathCanon.canonical(path))
        }
    }
}

extension Store {
    /// Hides a repository everywhere it would otherwise be surfaced.
    ///
    /// One list for both the detector and the live view, so "I don't want to see
    /// this" means the same thing in both places and is undone in one place.
    public func ignore(path: String, reason: String = "") throws {
        try database.writer.write { db in
            try IgnoredPath(
                path: FilePathCanon.canonical(path), reason: reason
            ).save(db)
        }
    }
}
