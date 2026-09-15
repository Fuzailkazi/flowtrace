import Foundation
import FlowTraceCore

/// Credential shapes, addresses, and the choke points that stop either reaching
/// the database.
///
/// The fake credentials here need two bounds to be useful: long enough to trip
/// FlowTrace's own rule, short enough not to look like a real provider key to a
/// secret scanner. Each one is commented with why its length is what it is.
func runPrivacyTests() {
    TestKit.suite("Credential shapes")

    // Each provider's prefix, with a body just over FlowTrace's threshold.
    TestKit.test("every prefix FlowTrace knows about is removed") {
        let cases: [(String, String, String)] = [
            ("stripe live", "rotate sk_live_0123456789abcdefgh today", "api key"),
            ("stripe restricted", "rotate rk_test_0123456789abcdefgh today", "api key"),
            ("github fine-grained", "use github_pat_0123456789abcdefghij now", "token"),
            ("gitlab", "use glpat-0123456789abcdefghij now", "token"),
            ("google oauth", "refresh with ya29.0123456789abcdefghij now", "token"),
            ("hugging face", "set hf_0123456789abcdefghijkl please", "api key"),
            ("npm", "publish with npm_0123456789abcdefghijkl ok", "token"),
            ("slack app", "install xapp-1-A0123456789 first", "token"),
            ("sendgrid", "mail via SG.0123456789abcdef.0123456789abcdef now", "api key"),
        ]
        for (label, input, marker) in cases {
            let result = Redaction.redact(input)
            expect(result.redactionCount >= 1, "\(label) was not redacted: \(input)")
            expectContains(result.text, "[\(marker) removed]")
            // The sentence has to survive, or the memory aid is destroyed.
            let firstWord = String(input.split(separator: " ").first ?? "")
            expectContains(result.text, firstWord)
        }
    }

    // The header-only rule left the body of the key sitting in the database.
    TestKit.test("a private key is removed as one block, body and all") {
        let key = """
        here is the deploy key
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB
        AAAAMwAAAAtzc2gtZW	QyNTUxOQAAACDb3BlbnNzaC1rZXktdjE
        -----END OPENSSH PRIVATE KEY-----
        use it for staging
        """
        let result = Redaction.redact(key)
        expectContains(result.text, "[private key removed]")
        expect(!result.text.contains("b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ"),
               "the body went with the header")
        expectContains(result.text, "use it for staging")
    }

    TestKit.test("a truncated key header is still caught") {
        let result = Redaction.redact("pasted -----BEGIN RSA PRIVATE KEY----- and lost the rest")
        expectContains(result.text, "[private key removed]")
    }

    TestKit.test("a prompt that was only a token is recognised as content-free") {
        expect(Redaction.isOnlyRedactions(Redaction.redact("github_pat_0123456789abcdefghij")),
               "nothing but a token")
        expect(!Redaction.isOnlyRedactions(
            Redaction.redact("swap github_pat_0123456789abcdefghij for the new one")
        ), "a real sentence survives")
    }

    TestKit.suite("Addresses")

    TestKit.test("credential-shaped parameters are blanked and the address stays readable") {
        expectEqual(
            Redaction.redactURL("https://x.example/a?token=abcdef0123456789&page=2"),
            "https://x.example/a?token=removed&page=2"
        )
        expectContains(
            Redaction.redactURL("https://s3.example/o?X-Amz-Signature=0123456789abcdef&x=1"),
            "X-Amz-Signature=removed"
        )
        expectContains(
            Redaction.redactURL("https://x.example/cb#access_token=0123456789abcdef&state=ok"),
            "access_token=removed"
        )
    }

    // A fragment is usually a heading, and blanking it would destroy the one
    // thing that made the address recognisable a week later.
    TestKit.test("a plain fragment is left alone") {
        let url = "https://acme.example/careers/#open-roles"
        expectEqual(Redaction.redactURL(url), url)
    }

    // `?key=name` is a sort order; `?key=<long>` is not.
    TestKit.test("short values that only look like secrets are kept") {
        expectEqual(Redaction.redactURL("https://x.example/a?key=name"),
                    "https://x.example/a?key=name")
        expectContains(Redaction.redactURL("https://x.example/a?key=0123456789abcdef"),
                       "key=removed")
        // An OAuth callback is gone in a second; `?code=404` is a page people
        // write notes about.
        expectEqual(Redaction.redactURL("https://x.example/e?code=404&state=CA"),
                    "https://x.example/e?code=404&state=CA")
    }

    TestKit.test("a password in the address is blanked") {
        expectContains(Redaction.redactURL("https://sam:hunter2@db.example/app"), "removed@")
        expect(!Redaction.redactURL("https://sam:hunter2@db.example/app").contains("hunter2"))
    }

    // An untouched address must come back byte-identical: a URLComponents round
    // trip can re-encode `+`, collapse empty items and re-bracket IPv6 hosts.
    TestKit.test("an address with nothing to blank is returned exactly as it came") {
        for url in [
            "https://example.com/docs?q=a+b%20c",
            "https://example.com/a?x=1&&y=2",
            "not a url at all",
            "https://[2001:db8::1]:8080/path",
        ] {
            expectEqual(Redaction.redactURL(url), url, "changed: \(url)")
        }
    }

    TestKit.test("blanking twice is the same as blanking once") {
        let once = Redaction.redactURL("https://x.example/a?token=abcdef0123456789")
        expectEqual(Redaction.redactURL(once), once)
    }

    TestKit.suite("Nothing sensitive reaches storage")

    func store() throws -> Store { try Store(database: FlowTraceDatabase.inMemory()) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    // The failure this whole phase exists for: a tokenised address written
    // verbatim, and then written again on the recorder's next tick because the
    // raw value never equalled the stored one.
    TestKit.test("a tokenised address is stored blanked, and does not split its span") {
        let store = try store()
        let raw = "https://s3.example/report?X-Amz-Signature=0123456789abcdef"
        for minute in 0..<3 {
            try store.beginActivity(ActivityEvent(
                kind: .browserTab,
                startedAt: base.addingTimeInterval(Double(minute) * 30),
                appName: "Brave Browser", target: "Report", url: raw
            ))
        }
        let day = try store.allActivity(on: base, minimumSeconds: 0)
        expectEqual(day.count, 1, "one span, not one per tick")
        expect(!(day.first?.url ?? "").contains("0123456789abcdef"), "the signature is gone")
        expectContains(day.first?.url ?? "", "X-Amz-Signature=removed")
    }

    // A terminal window title of this shape is matched by the VAR=value rule.
    TestKit.test("a window title carrying a secret is stored redacted and still coalesces") {
        let store = try store()
        let title = "AWS_SECRET_KEY=abcdefgh12345678 — zsh"
        for minute in 0..<2 {
            try store.beginActivity(ActivityEvent(
                kind: .app, startedAt: base.addingTimeInterval(Double(minute) * 30),
                appName: "Terminal", target: title
            ))
        }
        let day = try store.allActivity(on: base, minimumSeconds: 0)
        expectEqual(day.count, 1, "one span")
        expect(!(day.first?.target ?? "").contains("abcdefgh12345678"))
        expectContains(day.first?.target ?? "", "removed")
    }

    // Stored blanked, looked up blanked — otherwise the note written against a
    // page with a token in its address could never be found again.
    TestKit.test("a note on a tokenised page is found by its raw address") {
        let store = try store()
        let raw = "https://app.example/r?token=abcdef0123456789"
        try store.noteTab(url: raw, title: "Report", browser: "Brave Browser",
                          note: "checking the export")

        expectEqual(try store.noteForTab(url: raw), "checking the export",
                    "found with the address as the browser reports it")
        let stored = try store.notedTabs().first
        expect(!(stored?.url ?? "").contains("abcdef0123456789"), "stored blanked")
    }

    TestKit.test("a title that was nothing but a credential is stored as no title") {
        let store = try store()
        try store.recordActivity(ActivityEvent(
            kind: .app, startedAt: base, endedAt: base,
            appName: "Terminal", target: "ghp_0123456789abcdefghij"
        ))
        let row = try store.allActivity(on: base, minimumSeconds: 0).first
        expect(row?.target == nil, "a row labelled '[token removed]' is not a label")
    }

    TestKit.test("metadata written through describe is filtered too") {
        let store = try store()
        let span = try store.beginActivity(ActivityEvent(
            kind: .app, startedAt: base, appName: "VS Code"
        ))
        try store.describeActivity(id: span.id, metadata: ["asked": "use ghp_0123456789abcdefghij"])
        let row = try store.activity(id: span.id)
        expect(!(row?.metadata["asked"] ?? "").contains("ghp_0123456789abcdefghij"))
    }

    TestKit.suite("Repairing what was already stored")

    // Everything the migration has to reach, in one database.
    TestKit.test("the repair clears the cache and redacts every stored representation") {
        let database = try FlowTraceDatabase.inMemory()
        let store = Store(database: database)
        let secret = "ghp_0123456789abcdefghij"

        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO scanCache (filePath, fileSize, modifiedAt, payload, cachedAt)
                VALUES ('/tmp/a.jsonl', 10, '2026-01-01', ?, '2026-01-01')
                """, arguments: ["{\"lastPrompt\":\"use \(secret)\"}"])
            try db.execute(sql: """
                INSERT INTO workThread (id, title, description, intent, nextStep, tags,
                    createdAt, updatedAt, origin)
                VALUES ('t1', 'acme', '', ?, 'ship it', '[]', '2026-01-01', '2026-01-01', 'manual')
                """, arguments: ["use \(secret)"])
            try db.execute(sql: """
                INSERT INTO activityEvent (id, kind, startedAt, appName, target, url, metadata)
                VALUES ('a1', 'browserTab', '2026-01-01', 'Brave Browser', ?, ?, ?)
                """, arguments: [
                    "AWS_SECRET_KEY=abcdefgh12345678",
                    "https://x.example/a?token=abcdef0123456789",
                    "{\"asked\":\"use \(secret)\"}",
                ])
            try db.execute(sql: """
                INSERT INTO searchIndex (kind, recordId, threadId, title, body)
                VALUES ('thread', 't1', 't1', 'acme', ?)
                """, arguments: ["use \(secret)"])
        }

        try database.writer.write { db in try Store.redactStoredText(db) }

        try database.writer.read { db in
            expectEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM scanCache"), 0,
                        "the memo is rebuilt by the next scan, redacted")

            let intent = try String.fetchOne(db, sql: "SELECT intent FROM workThread WHERE id = 't1'")
            expect(!(intent ?? "").contains(secret), "thread intent")

            let target = try String.fetchOne(db, sql: "SELECT target FROM activityEvent WHERE id = 'a1'")
            let url = try String.fetchOne(db, sql: "SELECT url FROM activityEvent WHERE id = 'a1'")
            let metadata = try String.fetchOne(db, sql: "SELECT metadata FROM activityEvent WHERE id = 'a1'")
            expect(!(target ?? "").contains("abcdefgh12345678"), "window title")
            expect(!(url ?? "").contains("abcdef0123456789"), "address")
            expect(!(metadata ?? "").contains(secret), "metadata")

            // The index is standalone, so updating the rows above is not enough.
            let bodies = try String.fetchAll(db, sql: "SELECT body FROM searchIndex")
            expect(!bodies.contains { $0.contains(secret) }, "search index")
            expect(!bodies.isEmpty, "and it was rebuilt, not just emptied")
        }
    }

    // A row whose JSON will not decode must be left alone rather than throwing:
    // a throw inside a migration propagates out of `FlowTraceDatabase.init` and
    // the app fails to open its database on every launch after that.
    TestKit.test("a row with undecodable evidence survives the repair") {
        let database = try FlowTraceDatabase.inMemory()
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO threadProposal (id, repositoryPath, branch, suggestedTitle,
                    suggestedIntent, suggestedNextStep, score, evidence, state,
                    firstSeenAt, lastSeenAt)
                VALUES ('p1', '/tmp/acme', 'main', 'acme · main', ?, '', 1.0,
                    'not json at all', 'pending', '2026-01-01', '2026-01-01')
                """, arguments: ["use ghp_0123456789abcdefghij"])
        }

        try database.writer.write { db in try Store.redactStoredText(db) }

        try database.writer.read { db in
            let intent = try String.fetchOne(db, sql: "SELECT suggestedIntent FROM threadProposal WHERE id = 'p1'")
            let evidence = try String.fetchOne(db, sql: "SELECT evidence FROM threadProposal WHERE id = 'p1'")
            expect(!(intent ?? "").contains("ghp_"), "the plain column was still repaired")
            expectEqual(evidence, "not json at all", "the blob was left exactly as it was")
        }
    }

    TestKit.suite("Deleting means deleted")

    /// Points the log at a scratch directory so these never remove the real one.
    func withScratchLog(_ body: (URL) throws -> Void) rethrows {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = Diagnostics.directory
        Diagnostics.directory = directory
        defer {
            Diagnostics.directory = previous
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory)
    }

    TestKit.test("erasing what was recorded automatically empties the cache, pending proposals and the log") {
        try withScratchLog { _ in
            let database = try FlowTraceDatabase.inMemory()
            let store = Store(database: database)
            try Data("a line about your data\n".utf8).write(to: Diagnostics.fileURL)

            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO scanCache (filePath, fileSize, modifiedAt, payload, cachedAt)
                    VALUES ('/tmp/a.jsonl', 1, '2026-01-01', '{}', '2026-01-01')
                    """)
                for (id, state) in [("p1", "pending"), ("p2", "accepted")] {
                    try db.execute(sql: """
                        INSERT INTO threadProposal (id, repositoryPath, branch, suggestedTitle,
                            suggestedIntent, suggestedNextStep, score, evidence, state,
                            firstSeenAt, lastSeenAt)
                        VALUES (?, ?, 'main', 'acme', '', '', 1.0, '{}', ?, '2026-01-01', '2026-01-01')
                        """, arguments: [id, "/tmp/\(id)", state])
                }
            }
            try store.recordActivity(ActivityEvent(
                kind: .app, startedAt: base, endedAt: base, appName: "Slack"
            ))
            try store.recordActivity(ActivityEvent(
                kind: .app, startedAt: base, endedAt: base, appName: "VS Code",
                note: "why I was here", noteAt: base
            ))

            let erased = try store.deleteRawActivity()

            expectEqual(erased, 1, "the count is of activity rows, not proposals")
            try database.writer.read { db in
                expectEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM scanCache"), 0)
                expectEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM threadProposal"), 1,
                            "the accepted one carries a decision you made")
                expectEqual(try String.fetchOne(db, sql: "SELECT state FROM threadProposal"), "accepted")
            }
            expectEqual(try store.activity(on: base, minimumSeconds: 0).count, 1, "your note is kept")
            expect(!FileManager.default.fileExists(atPath: Diagnostics.fileURL.path),
                   "the log went with it")
        }
    }

    TestKit.test("holdings count the cache and the log") {
        try withScratchLog { _ in
            let database = try FlowTraceDatabase.inMemory()
            let store = Store(database: database)
            try Data(repeating: 0, count: 2_048).write(to: Diagnostics.fileURL)
            try database.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO scanCache (filePath, fileSize, modifiedAt, payload, cachedAt)
                    VALUES ('/tmp/a.jsonl', 1, '2026-01-01', '{}', '2026-01-01')
                    """)
            }

            let holdings = try store.holdings()
            expectEqual(holdings.parsedTranscripts, 1, "the memo is held, so it is counted")
            expectEqual(holdings.diagnosticsBytes, 2_048)
            expect(!holdings.isEmpty, "a cache with rows in it is not nothing")
        }
    }

    TestKit.test("deleting everything leaves nothing in the index or the log") {
        try withScratchLog { _ in
            let database = try FlowTraceDatabase.inMemory()
            let store = Store(database: database)
            try Data("a line\n".utf8).write(to: Diagnostics.fileURL)
            _ = try store.create(WorkThread(title: "acme", intent: "ship the thing"))

            try database.writer.read { db in
                expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM searchIndex") ?? 0 > 0,
                       "indexed to begin with")
            }

            try store.deleteAllData()

            try database.writer.read { db in
                expectEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM searchIndex"), 0,
                            "the index is standalone and has to be emptied by name")
                expectEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM workThread"), 0)
            }
            expect(!FileManager.default.fileExists(atPath: Diagnostics.fileURL.path))
        }
    }

    // Invariant 4: the rules are in the database, not in a running process.
    TestKit.test("privacy survives relaunch: reopening the same file keeps it clean") {
        try withScratchLog { directory in
            let file = directory.appendingPathComponent("relaunch.sqlite")
            let raw = "https://x.example/a?token=abcdef0123456789"

            do {
                let store = try Store(url: file)
                try store.noteTab(url: raw, title: "Report", browser: "Brave Browser",
                                  note: "the export")
            }

            // A second process opening the same database, as a relaunch does.
            let reopened = try Store(url: file)
            let stored = try reopened.notedTabs().first
            expect(!(stored?.url ?? "").contains("abcdef0123456789"), "still blanked")
            expectEqual(try reopened.noteForTab(url: raw), "the export",
                        "and still findable by the address you see in the browser")
        }
    }
}

/// The adapter choke point, end to end: a transcript carrying credentials is
/// parsed, cached and read back, and nothing raw survives the trip.
///
/// A separate fixture root from `Fixtures/claude`, whose tests assert a single
/// session and use `.first`.
func runRedactionFixtureTests(fixtures: URL) {
    TestKit.suite("A transcript with keys in it")

    let root = fixtures.appendingPathComponent("claude-redaction")
    let adapter = ClaudeCodeAdapter(root: root)

    TestKit.test("prompts are redacted as the transcript is parsed") {
        let sessions = try adapter.discoverSessions()
        let session = try unwrap(sessions.first)

        expect(!(session.firstPrompt ?? "").contains("sk_live_"), "first prompt")
        expectContains(session.firstPrompt, "[api key removed]")
        expectContains(session.firstPrompt, "tell me if it works")
        expect(!(session.title ?? "").contains("sk_live_"), "the session's own title")

        for prompt in session.recentPrompts {
            expect(!prompt.contains("sk_live_"), "arc: \(prompt)")
            expect(!prompt.contains("github_pat_"), "arc: \(prompt)")
        }
    }

    // A turn that was only a pasted token says nothing about what the user was
    // doing, so it is dropped — but it still happened, and the count says so.
    TestKit.test("a turn that was only a token is dropped but still counted") {
        let session = try unwrap(try adapter.discoverSessions().first)
        expectEqual(session.messageCount, 3, "three turns were taken")
        expect(!(session.lastPrompt ?? "").contains("github_pat_"), "not kept as a prompt")
        expectEqual(session.lastPrompt, "now deploy the staging environment and watch the logs")
    }

    // The failure that started this: the cache held the raw session payload.
    TestKit.test("nothing raw reaches the scan cache") {
        let database = try FlowTraceDatabase.inMemory()
        let store = Store(database: database)
        let cache = StoreSessionCache(store: store)

        _ = try ClaudeCodeAdapter(root: root).discoverSessions(cache: cache)
        cache.flush()

        try database.writer.read { db in
            let payloads = try String.fetchAll(db, sql: "SELECT payload FROM scanCache")
            expect(!payloads.isEmpty, "something was cached")
            for payload in payloads {
                expect(!payload.contains("sk_live_"), "a live key reached the cache")
                expect(!payload.contains("github_pat_"), "a token reached the cache")
            }
            expect(payloads.contains { $0.contains("removed") }, "and it was redacted, not dropped")
        }
    }
}
