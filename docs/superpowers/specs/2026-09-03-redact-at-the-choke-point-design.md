# Redact at the choke point

Sub-project C of Tier 0 in `docs/superpowers/audits/2026-09-03-product-audit-and-launch-roadmap.md` (items 0.3 and 1.9). Independent of **B — nothing is read before you say so**.

## Problem

The README promises "Credentials are stripped before they are stored … redacted at the point text leaves the transcript", and the onboarding consent step says credentials "are never read or stored". `Redaction` exists and works — but it is applied in three consumers (`SessionImporter`, `LiveStateReader`, `BriefBuilder`) and nowhere in the path that actually persists prompts:

1. `ClaudeCodeAdapter.parse` and `CodexAdapter.parse` build an `AgentSession` from raw prompt text (`firstPrompt`, `lastPrompt`, `lastSubstantivePrompt`, `recentPrompts`, `title`) and call `cache?.store(session, …)`; `StoreSessionCache.store` JSON-encodes the whole session into `scanCache.payload` (`Sources/FlowTraceCore/Store/Store+Proposals.swift`). On the author's real database, read-only: 188 `scanCache` rows, two payloads containing `sk-` keys, zero containing `[api key removed]`.
2. `AbandonedWorkDetector` copies those prompts into `ThreadProposal.suggestedIntent`/`suggestedNextStep`/`evidence.lastPrompt`/`evidence.promptArc`, which render on `ThreadCard` and in `flowtrace scan`; `Store.accept(proposal:)` copies them again into `workThread.intent`/`nextStep` and `codeContext.note`/`nextStep`.
3. URLs are stored verbatim by the recorder (`ActivityRecorder.captureFrontmost`), by tab notes (`Store.noteTab`), and by the extension endpoint (`LocalServerRoutes.captureTabs` → `Store.attach(tabs:)`). The real database holds one URL carrying `token=` and `X-Amz-Signature=` query values.
4. `Store.holdings()` counts only `activityEvent` and `projectNote`, and `deleteRawActivity()` deletes only from `activityEvent` — so "What FlowTrace knows" under-reports what is held, and "Erase what was recorded automatically" leaves the cache, the proposals and `debug.log` (`Diagnostics.fileURL`, never cleared: `Diagnostics.clear()` has no callers) untouched.

The pattern list itself also misses common shapes: `sk_live_`/`sk_test_`/`rk_live_` (only `sk-` with a hyphen is matched), `github_pat_`, `glpat-`, `xapp-`, `ya29.`, `hf_`, `npm_`, `SG.`; and the private-key rule matches only the header line, leaving the key body.

## Approach

Redact once, where text enters the system — in the adapters for prompts, in the `Store` for URLs — so every consumer downstream (cache, proposals, threads, brief, Now, CLI) is clean by construction. Repair what is already stored with one migration. Make Holdings and the erase actions cover everything automatic. Existing downstream redaction stays where it is (idempotent: markers contain no credential shapes), so nothing depends on a single line.

Rejected: redacting at display time (leaves the database dirty — the README's claim is about storage), and redacting inside `StoreSessionCache.store` only (would still leave `ThreadProposal` and the CLI path raw).

## Design

### 1. Prompts are redacted as they are parsed

In `ClaudeCodeAdapter.parse` (`case "user"`) and `CodexAdapter.parse` (`user_message`), immediately after the raw `text` is obtained:

```swift
let redacted = Redaction.redact(text)
messageCount += 1
guard !Redaction.isOnlyRedactions(redacted), !redacted.isEmpty else { continue }
let clean = redacted.text
// firstPrompt / lastPrompt / lastSubstantivePrompt / arc use `clean`;
// AgentSession.isSubstantive is evaluated on `clean`.
```

`ai-title` values go through `Redaction.redact` too (titles are derived from prompts). `SessionImporter`, `LiveStateReader` and `BriefBuilder` keep their existing redaction calls.

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

`isOnlyRedactions` derives its marker list from `patterns.map(\.name)` instead of the hard-coded array, so a new name can never be missed.

### 3. `Redaction.redactURL`

```swift
/// Blanks credential-shaped query and fragment values, keeping the key so
/// the address stays recognisable: `…?token=removed&page=2`.
public static func redactURL(_ url: String) -> String
```

Uses `URLComponents`. A query item whose name matches, case-insensitively, `^(token|access_token|id_token|refresh_token|api[_-]?key|apikey|key|secret|client_secret|signature|sig|x-amz-signature|x-amz-credential|x-amz-security-token|password|passwd|pwd|auth|authorization|session|sessionid|sid|code|state)$` has its value replaced with `removed`. The fragment is treated the same way only when it parses as `k=v(&k=v)*`; a plain fragment (`#open-roles`) is kept. A string `URLComponents` cannot parse is returned unchanged. Applied to `ActivityEvent.url` and `BrowserContext.url`.

### 4. The `Store` is the one place URLs are written — and looked up

A private `Store.storageURL(_ url: String?) -> String?` (`Redaction.redactURL`) is applied in every write path that carries a URL: `beginActivity`, `recordActivity`, `describeActivity`, `upsertImportedActivity`, `noteTab`, and `attach(tabs:)`. The same function is applied to the *key* in every lookup by URL — `existingTabEvent(url:)`/`noteForTab(url:)`, `threadForURL(_:)` — so a live tab whose address carries a token still finds the note stored under its blanked form. Callers (recorder, panel, extension route) do not change.

### 5. Migration `v6.redactStored`

Registered after `v5.projectNote` in `Store/Migrations.swift`; body is `try Store.redactStoredText(db)` from a new `Store+Redaction.swift` so the same routine is unit-testable on a fresh database:

- `DELETE FROM scanCache` — the memo is rebuilt, redacted, on the next scan.
- For each row, rewrite through `Redaction.redact`: `threadProposal.suggestedTitle/suggestedIntent/suggestedNextStep/evidence` (evidence is a JSON string; redact it as text), `workThread.title/description/intent/nextStep/detectionEvidence`, `codeContext.note/nextStep`, `activityEvent.metadata` (JSON; redact as text), `activityEvent.target`.
- Rewrite through `Redaction.redactURL`: `activityEvent.url`, `browserContext.url`.
- Rows whose text is unchanged are not written (keeps the migration quick on large stores).

### 6. Holdings and erasure tell the whole truth

- `Holdings` gains `parsedTranscripts: Int` (`SELECT count(*) FROM scanCache`) and `diagnosticsBytes: Int64` (size of `Diagnostics.fileURL`, 0 if absent). `SettingsView` adds rows "Parsed transcripts — a memo of your agent sessions, so a rescan is fast" and "Diagnostics log — what the app wrote about itself".
- `deleteRawActivity()` additionally runs `DELETE FROM scanCache`, `DELETE FROM threadProposal WHERE state = 'pending'` (accepted and dismissed carry decisions you made), and calls `Diagnostics.clear()`. Its doc comment ("erase the surveillance, keep the journal") already describes this.
- `deleteAllData()` calls `Diagnostics.clear()` after emptying the tables.

### 7. Copy made true

- `OnboardingView` consent card: "Assistant replies, file contents and tool output are never read. Keys, tokens and passwords are stripped from prompts before anything is stored." (replaces "…credentials are never read or stored" — a key *is* read from the transcript; it is stripped, not unseen).
- `README.md` "Credentials are stripped before they are stored" paragraph is now literally true and stays. Its "one SQLite file" sentence is corrected in E (launch wrapper) along with the other README drift.

### 8. Out of scope

Consent gating (B). Search over notes (Tier 1.4). Any redaction of window titles beyond `activityEvent.target` (titles rarely carry secrets; revisit if a real case appears).

## Testing

`Sources/FlowTraceTests/BriefTests.swift` (Redaction suite):
- Each new pattern redacts a synthetic example and leaves the surrounding words; `sk_live_` no longer relies on the `VAR=` rule (test a bare `sk_live_…` with no variable name).
- A full private-key block is replaced with a single `[private key removed]`; a header-only fragment still matches.
- `redactURL`: `?token=abc&page=2` → `?token=removed&page=2`; `X-Amz-Signature=` blanked; `#access_token=…` blanked; `#open-roles` kept; `https://example.com/docs?q=redaction` unchanged; a non-URL string unchanged.
- `isOnlyRedactions` is true for a prompt that was only a `github_pat_` token.

New `Sources/FlowTraceTests/Fixtures/claude/-Users-dev-keys/…jsonl` (test-only, fake credential shapes) and a case in the adapter suite: parsing it yields `firstPrompt` containing `[api key removed]` and no `sk-`; storing through `StoreSessionCache` and reading `scanCache.payload` back finds no `sk-`.

`ActivityTests.swift` / a new `RedactionStoreTests.swift`:
- `noteTab(url: "…?token=abc", …)` then `noteForTab(url: "…?token=abc")` returns the note, and the stored `url` is `…?token=removed`.
- `redactStoredText`: insert a `scanCache` row, a pending `threadProposal` with a key in `suggestedNextStep`, and an `activityEvent` with a tokenised URL → after the routine, `scanCache` is empty, the proposal reads `[api key removed]`, the URL is blanked.
- `deleteRawActivity` empties `scanCache` and pending proposals, keeps an accepted proposal, and removes `debug.log`.
- `holdings().parsedTranscripts` reflects `scanCache` count.

## Manual verification

1. On the author's real database (after backing it up): launch the dev build once → migration runs; `sqlite3 … "SELECT count(*) FROM scanCache"` is 0; `grep -c 'sk-' <(sqlite3 … "SELECT payload FROM scanCache; SELECT suggestedNextStep FROM threadProposal")` is 0; Settings → What FlowTrace knows shows "Parsed transcripts 0" and the diagnostics log size.
2. Run `flowtrace scan` and Now: prompts render with `[api key removed]` markers where keys were; no raw key appears.
3. Open a page with `?token=…` in the URL, press the capture key, save: Today shows the page; the raw view / `sqlite3` shows `token=removed`; press the key again on the same tab — the note is found (Tier 1.1 will render it; for now confirm via `noteForTab` in the raw view or Now's tab list).
4. Erase what was recorded automatically → Parsed transcripts 0, pending proposals gone, an accepted thread still present, `debug.log` gone.
