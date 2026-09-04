# Redact at the choke point

Sub-project C of Tier 0 in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` (items 0.3 and 1.9). Independent of **B — nothing is read before you say so**. Builds after **A — capture lands where you pressed the key** and amends one line of it (§4).

## Problem

The README promises "Credentials are stripped before they are stored … redacted at the point text leaves the transcript", and the onboarding consent step says credentials "are never read or stored". `Redaction` exists and works — but it is applied in exactly three consumers (`SessionImporter`, `LiveStateReader`, `BriefBuilder`) and nowhere in the path that actually persists prompts:

1. `ClaudeCodeAdapter.parse` and `CodexAdapter.parse` build an `AgentSession` from raw prompt text (`firstPrompt`, `lastPrompt`, `lastSubstantivePrompt`, `recentPrompts`, and Claude's `ai-title`; Codex's title is attached afterwards in `loadTitles()` from `session_index.jsonl`) and call `cache?.store(session, …)`; `StoreSessionCache.store` JSON-encodes the whole session into `scanCache.payload` (`Sources/FlowTraceCore/Store/Store+Proposals.swift`). On the author's real database, read-only: 188 `scanCache` rows, two payloads containing `sk-` keys, zero containing `[api key removed]`.
2. `AbandonedWorkDetector` copies those prompts into `ThreadProposal.suggestedIntent`/`suggestedNextStep` and `evidence.lastPrompt`/`promptArc`/`sessionTitle`, which render on `ThreadCard` and in `flowtrace scan`; `Store.accept(proposal:)` copies them again into `workThread.intent`/`nextStep`, `codeContext.nextStep`, and — via `Store.create`/`resume`/`diffEvents` — into `timelineEvent.description`; and `Store.reindex` writes `intent`/`nextStep` into the standalone FTS table `searchIndex` (`Migrations.swift`, `v1.search`, "kept in sync explicitly by SearchIndex rather than by triggers"). (`codeContext.note` is `evidence.reasons` — counts, not prompts; `suggestedTitle`/`workThread.title` are `repo · branch`. Neither is prompt-derived.)
3. URLs are stored verbatim by the recorder (`ActivityRecorder.captureFrontmost`), by tab notes (`Store.noteTab`), and by the extension endpoint (`LocalServerRoutes.captureTabs` → `Store.attach(tabs:)`). The real database holds one URL carrying `token=` and `X-Amz-Signature=` query values.
4. `Store.holdings()` counts only `activityEvent` and `projectNote`, and `deleteRawActivity()` deletes only from `activityEvent` — so "What FlowTrace knows" under-reports what is held, and "Erase what was recorded automatically" leaves the cache, the proposals and `debug.log` (`Diagnostics.fileURL`; `Diagnostics.clear()` has no callers) untouched.

The pattern list itself misses common shapes: `sk_live_`/`sk_test_`/`rk_live_` (only `sk-` with a hyphen is matched), `github_pat_`, `glpat-`, `xapp-`, `ya29.`, `hf_`, `npm_`, `SG.`; and the private-key rule matches only the header line, leaving the key body.

## Approach

Redact once, where text enters the system — in the adapters for prompts, in the `Store` for URLs — so every consumer downstream (cache, proposals, threads, timeline, search index, brief, Now, CLI) is clean by construction. Repair what is already stored with one migration that decodes structured columns rather than regexing serialised JSON, and rebuilds the search index. Make Holdings and the erase actions cover everything automatic. Existing downstream redaction stays where it is (idempotent: markers contain no credential shapes), so nothing depends on a single line.

Rejected: redacting at display time (leaves the database dirty — the README's claim is about storage), and redacting inside `StoreSessionCache.store` only (would still leave `ThreadProposal` and the CLI path raw).

## Design

### 1. Prompts are redacted as they are parsed

In `ClaudeCodeAdapter.parse` (`case "user"`) and `CodexAdapter.parse` (`user_message`), immediately after the raw `text` is obtained:

```swift
let redacted = Redaction.redact(text)
messageCount += 1          // a message was sent, even if it was only a key
guard !Redaction.isOnlyRedactions(redacted), !redacted.isEmpty else { continue }
let clean = redacted.text
// firstPrompt / lastPrompt / lastSubstantivePrompt / arc use `clean`;
// AgentSession.isSubstantive is evaluated on `clean`.
```

Claude's `ai-title` values and Codex's `thread_name` (in `CodexAdapter.loadTitles()`) go through `Redaction.redact` too. `SessionImporter`, `LiveStateReader` and `BriefBuilder` keep their existing redaction calls.

### 2. `Redaction` covers more shapes

Add to `patterns`, each anchored on a prefix as today:

| name | pattern |
|---|---|
| api key | `\bsk_(?:live\|test)_[A-Za-z0-9]{16,}` and `\brk_(?:live\|test)_[A-Za-z0-9]{16,}` |
| token | `\bgithub_pat_[A-Za-z0-9_]{20,}` |
| token | `\bglpat-[A-Za-z0-9_-]{20,}` |
| token | `\bxapp-[A-Za-z0-9-]{10,}` |
| token | `\bya29\.[A-Za-z0-9_-]{20,}` |
| api key | `\bhf_[A-Za-z0-9]{20,}` |
| token | `\bnpm_[A-Za-z0-9]{20,}` |
| api key | `\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}` |
| private key | `-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----` (listed *before* the existing header-only rule, which stays as the fallback for a truncated block) |

**Order matters and is part of the change.** `redact` applies patterns in array order, so the new rows go in the positions shown, not appended: the `sk_`/`rk_` "api key" rows sit beside the existing `sk-` rule at the head of the list, *before* the `secret` (`VAR=value`) rule, and the full private-key rule immediately before the header-only one. That ordering is what changes an existing test's expectation: `export STRIPE_SECRET_KEY=sk_live_0123456789abcdef` (`BriefTests.swift`) currently reports `secret` only because no `sk_live_` rule exists; with the rows appended instead of inserted it would keep reporting `secret` and the fix would be half-done.

`isOnlyRedactions` derives its marker list from `patterns.map(\.name)` instead of the hard-coded array, so a new name can never be missed.

### 3. `Redaction.redactURL`

```swift
/// Blanks credential-shaped query and fragment values, keeping the key so
/// the address stays recognisable: `…?token=removed&page=2`. Idempotent, and
/// returns the input string unchanged when nothing was blanked.
public static func redactURL(_ url: String) -> String
```

- Parse with `URLComponents`. Work on `percentEncodedQueryItems` and `percentEncodedFragment`, not their decoded counterparts, so an untouched URL is not re-encoded (`+`, `%20`, reserved characters) on the way through; if no item, fragment or password changed, **return the original string**. That escape hatch matters beyond encoding: an edit-free `URLComponents` round trip can still alter text (an empty query item in `?a=b&&c=d` collapses, nil-versus-empty values are asymmetric, IPv6 hosts have been re-bracketed), and returning the input sidesteps all of it.
- Always blank (case-insensitive name match): `token`, `access_token`, `id_token`, `refresh_token`, `api_key`, `api-key`, `apikey`, `secret`, `client_secret`, `signature`, `x-amz-signature`, `x-amz-credential`, `x-amz-security-token`, `password`, `passwd`, `pwd`, `auth`, `authorization`, `session`, `sessionid`, `sid`.
- Blank only when the value is 16 characters or longer: `key`, `sig` (short values are sort keys and page codes, and the blanked address is what "Pages you wrote about" will render). `code` and `state` are deliberately *not* blanked: OAuth callbacks are gone in a second and nobody notes them, while `?code=404`/`?state=CA` are pages people do write about.
- A `user:password@host` password (`URLComponents.password`) is blanked to `removed`.
- The fragment is treated like the query only when it parses as `k=v(&k=v)*`; a plain fragment (`#open-roles`) is kept.
- A string `URLComponents` cannot parse is returned unchanged.

### 4. The `Store` is the one place URLs are written — and compared

`public static func Store.storageURL(_ url: String?) -> String?` (`Redaction.redactURL`, nil-passing), and alongside it `public static func Store.storageText(_ text: String?) -> String?` (`Redaction.redact`, dropping a value that is only markers). Both are applied **to the incoming event as the first statement** of every write path, *before* any comparison — `event.url = storageURL(event.url); event.target = storageText(event.target)` — on `beginActivity` (before both `describesSameActivity` calls), `recordActivity`, `upsertImportedActivity`, `describeActivity(id:target:url:)`, `noteTab` (both the `existingTabEvent` lookup key and the inserted event), and `attach(tabs:)` (URL only; a page title is not a window title).

Both fields matter for the same two reasons. A raw incoming value never equals the stored blanked one, and `describesSameActivity` compares `target` as well as `url`, so leaving either raw makes a tokenised page — or a terminal window title of the shape `SOMETHING_TOKEN=abc123…`, which the existing `secret` rule matches — close and reopen its span on every 30-second tick. And `target` is the one title column §5 repairs; without a write-side rule the recorder would put the credential straight back on the next app switch, so §7's claim would be false by the next tick.

Lookups by URL — `existingTabEvent(url:)`/`noteForTab(url:)`, `threadForURL(_:)` — canonicalise their key the same way, so a live tab whose address carries a token still finds the note stored under its blanked form. Callers (recorder, panel, extension route) pass raw values and do not change.

**Any comparison of a live URL against a stored one outside the Store must compare canonical forms.** The one current case is spec A's `CaptureTargeting.plan`, which compares `open.url == site.url`. This sub-project makes `FrontmostSnapshot.site` map `url` through `Store.storageURL`, so the site is already in storage form and A's rule compares like with like; the "site as event" it builds therefore also carries the canonical URL.

### 5. Migration `v6.redactStored`

Registered after `v5.projectNote` in `Store/Migrations.swift`; body is `try Store.redactStoredText(db)` from a new `Store+Redaction.swift`, so the same routine is unit-testable on a fresh in-memory database. The migration runs in `FlowTraceDatabase.init`, before any `StoreSessionCache` is constructed, so clearing the cache is safe.

**It reads columns, never records.** Every step selects raw columns via SQL into `GRDB.Row`s and decodes each JSON blob inside a `try?`. A record-level `WorkThread.fetchAll(db)` or `ThreadProposal.fetchAll(db)` throws on one malformed JSON column, and a throw inside a migration propagates out of `FlowTraceDatabase.init` — the app would then fail to open its database on *every* launch, which is far worse than the single bad row this migration exists to clean. An undecodable blob is left exactly as it was, and its row is still repaired and re-indexed from its plain-text columns.

1. `DELETE FROM scanCache` — the memo is rebuilt, redacted, on the next scan.
2. **Plain-text columns**, rewritten through `Redaction.redact`: `threadProposal.suggestedTitle/suggestedIntent/suggestedNextStep`, `workThread.title/description/intent/nextStep`, `codeContext.note/nextStep`, `timelineEvent.description`, `activityEvent.target`.
3. **JSON columns are decoded, redacted field by field, and re-encoded — never regexed as text.** Two patterns (`secret`, `connection string`) end in `\S` runs that cross `"`, `,` and `]`, and `JSONEncoder` emits no whitespace, so a credential at the end of one string value would swallow the start of the next and leave an unterminated string; one broken `evidence` row makes `ThreadProposal.fetchAll` throw and `AppModel.refresh()` fail for the whole app. So: `threadProposal.evidence` and `workThread.detectionEvidence` decode as `DetectionEvidence` and redact `lastPrompt`, `promptArc`, `sessionTitle`, `lastCommitSubject`; `activityEvent.metadata` decodes as `[String: String]` and redacts values. A row that fails to decode is left untouched.
4. **URL columns**, through `storageURL`: `activityEvent.url`, `browserContext.url`.
5. **Rebuild the search index**: `DELETE FROM searchIndex`, then re-index every `workThread` with `Store.reindex(db, thread:)` (already `static` and takes a `Database`, so a migration can call it) and every `codeContext`/`browserContext`/`note` row that has a `workThreadId` with the same body builders the write paths use (`Store.swift`, `Store+Capture.swift`) — factored into shared helpers so the migration cannot drift from them. The index body uses only `title`/`description`/`intent`/`nextStep`/`blocker`/`tags`/`status`, never `detectionEvidence`, so a thread whose evidence would not decode is reconstructed for indexing with `detectionEvidence: nil` rather than skipped. The FTS table is standalone; an `UPDATE` on `workThread` alone would leave raw prompts in `searchIndex_content`/`_data`, which `userTables` excludes from "delete everything".
6. Rows whose text is unchanged are not written.

### 6. Holdings and erasure tell the whole truth

- `Holdings` gains `parsedTranscripts: Int` (`SELECT count(*) FROM scanCache`) and `diagnosticsBytes: Int64`; `isEmpty` includes `parsedTranscripts` but **not** `diagnosticsBytes` — a log the app wrote about itself is not the user's data, and counting it would make "nothing held" depend on whether a log file happens to exist. `SettingsView` adds rows "Parsed transcripts — a memo of your agent sessions, so a rescan is fast" and "Diagnostics log — what the app wrote about itself".
- `Diagnostics` gets a seam: `nonisolated(unsafe) public static var directory: URL = FlowTraceDatabase.supportDirectory`, with `fileURL` derived from it, so tests can point it at a scratch directory instead of deleting the developer's real log. `holdings()` and `deleteRawActivity()` read `Diagnostics.fileURL`.
- `deleteRawActivity()` additionally runs `DELETE FROM scanCache`, `DELETE FROM threadProposal WHERE state = 'pending'` (accepted and dismissed carry decisions you made), and calls `Diagnostics.clear()`. **Its return value must stay the count of erased activity rows**: `changesCount` reports only the most recent statement, so the existing `return db.changesCount` has to become a local captured immediately after the `activityEvent` delete, with the new deletes after it. Otherwise the Settings toast ("Removed N automatic records") reports the pending-proposal count and an existing test that expects a positive number fails on a fixture with no proposals. Its doc comment ("erase the surveillance, keep the journal") already describes the wider sweep. The Settings button also calls `model.refresh()` (as `deleteAll()` does), otherwise `model.proposals` keeps the deleted rows and accepting one creates a thread and then throws `recordNotFound`. A later rescan re-offers the same proposals, redacted — intended.
- `deleteAllData()` calls `Diagnostics.clear()` after emptying the tables. Because `log` appends asynchronously, a line emitted after the click can recreate the file; "emptied or gone" is the observable.

### 7. Copy made true

- `OnboardingView` consent card: "Assistant replies, file contents and tool output are never read. Keys, tokens and passwords are stripped from prompts before anything is stored." (replaces "…credentials are never read or stored" — a key *is* read from the transcript; it is stripped, not unseen).
- `README.md` "Credentials are stripped before they are stored" paragraph is now literally true and stays. Its "one SQLite file" sentence is corrected in E (launch wrapper) along with the other README drift.

### 8. Out of scope

Consent gating (B). Search over notes (Tier 1.4). Redaction of window titles beyond `activityEvent.target` (titles rarely carry secrets; revisit if a real case appears).

## Testing

`Sources/FlowTraceTests/BriefTests.swift` (Redaction suite):
- Each new pattern redacts a synthetic example and leaves the surrounding words; a bare `sk_live_…` with no variable name is caught; the Stripe `export` case now reports `api key`.
- A full private-key block is replaced with a single `[private key removed]`; a header-only fragment still matches.
- `redactURL`: `?token=abc&page=2` → `?token=removed&page=2`; `X-Amz-Signature=` blanked; `#access_token=…` blanked; `#open-roles` kept; `?key=name` kept, `?key=<20 chars>` blanked; `?code=404` kept; `https://user:pw@host/` → password blanked; `https://example.com/docs?q=a+b%20c` returned byte-identical; a non-URL string unchanged; applying it twice equals applying it once.
- `isOnlyRedactions` is true for a prompt that was only a `github_pat_` token.

New fixture root `Sources/FlowTraceTests/Fixtures/claude-redaction/-Users-dev-keys/…jsonl` — separate from `Fixtures/claude`, whose existing tests assert `count == 1` and use `.first`. No `Package.swift` change is needed; `resources: [.copy("Fixtures")]` already copies the whole tree.

The fake shapes need **both** bounds, or a fixture can sit below FlowTrace's own threshold and never be redacted, failing the assertion below for the wrong reason: an `sk_live_` body of 16–23 characters (≥16 trips the new rule, <24 stays under Stripe's partner pattern); a `github_pat_` body of 20–40 (≥20 trips the rule, far under the 82 GitHub's fine-grained shape needs); `sk-proj-` with a ~24-character body and no `T3BlbkFJ` infix. Add `.github/secret_scanning.yml` (the directory does not exist yet) with `paths-ignore: ["Sources/FlowTraceTests/Fixtures/**"]` — belt and braces only: it suppresses alerts, not push protection or partner-pattern forwarding, so the fake shapes are the actual defence.

Adapter test: parsing the fixture yields `firstPrompt` containing `[api key removed]` and no `sk-`; storing through `StoreSessionCache` and reading `scanCache.payload` back finds no `sk-`.

New `Sources/FlowTraceTests/RedactionStoreTests.swift`, **registered in `main.swift`'s call list** (in-memory store; `Diagnostics.directory` pointed at a temp dir):
- `beginActivity` with `url: "…?token=abc"` twice → one span (coalesced), stored URL `…?token=removed`; a raw-URL `beginActivity` after a 30s-tick-style repeat does not split the span. The same for a raw `target` of `AWS_SECRET_KEY=abcdefgh12345678` — stored redacted, and repeating it coalesces rather than splitting.
- `Diagnostics.directory` is pointed at a scratch directory **once in `main.swift`, before the first suite runs** — not inside this file. Three existing tests already call `deleteAllData()`/`deleteRawActivity()`, which now clear the log, so a per-suite seam would still delete the developer's real `debug.log` when the rest of the suite runs.
- `deleteRawActivity()` returns the number of erased *activity* rows even when there are no pending proposals to delete.
- `noteTab(url: "…?token=abc", …)` then `noteForTab(url: "…?token=abc")` returns the note; the stored `url` is blanked.
- `redactStoredText`: insert a `scanCache` row; a pending `threadProposal` whose `suggestedNextStep` and `evidence.lastPrompt` carry a key and whose `evidence.promptArc` ends with a `postgres://user:pw@host/db` string; an accepted proposal with a `workThread`, `codeContext`, `timelineEvent` and `searchIndex` row carrying the same key; an `activityEvent` with a tokenised URL and a key inside `metadata["asked"]` → afterwards `scanCache` is empty, every text column reads `[… removed]`, `evidence` and `metadata` still decode, `SELECT body FROM searchIndex` contains no `sk-`, the URL is blanked, and a row with undecodable `evidence` is unchanged.
- `deleteRawActivity` empties `scanCache` and pending proposals, keeps an accepted proposal, and removes the scratch `debug.log`.
- `holdings().parsedTranscripts` reflects `scanCache` count and `isEmpty` is false when only the cache has rows.

## Manual verification

1. On the author's real database (after backing it up): launch the dev build once → migration runs; `sqlite3 … "SELECT count(*) FROM scanCache"` is 0; `sqlite3 … "SELECT payload FROM scanCache UNION ALL SELECT suggestedNextStep FROM threadProposal UNION ALL SELECT body FROM searchIndex" | grep -c 'sk-'` is 0; Unfinished work still lists proposals and threads (nothing failed to decode); Settings → What FlowTrace knows shows "Parsed transcripts 0" and the diagnostics log size.
2. Run `flowtrace scan` and Now: prompts render with `[api key removed]` markers where keys were; no raw key appears.
3. Open a page with `?token=…` in the URL with recording on; wait two 30s ticks: the raw view shows one span, not three. Press the capture key, save: Today shows the page; the raw view shows `token=removed`; press the key again on the same tab — the panel's plan is `annotateOpen` (the field pre-fills with what you wrote, per spec A).
4. Erase what was recorded automatically → Parsed transcripts 0, pending proposals gone from Settings *and* from Unfinished work, an accepted thread still present, `debug.log` emptied or gone.
