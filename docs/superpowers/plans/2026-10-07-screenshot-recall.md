# Screenshot Recall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A person can save a screenshot, find it by visible or added words, reopen it, and delete it.

**Architecture:** Store normalized image bytes, OCR text, and metadata in SQLite; index text in FTS5. A focused SwiftUI library handles import, clipboard, browsing, detail, and errors. Vision runs locally.

**Tech Stack:** Swift 6 language mode 5, SwiftUI, AppKit, Vision, GRDB/SQLite FTS5.

---

### Task 1: Store and search

**Files:** `Sources/FlowTraceCore/Store/Migrations.swift`, `Sources/FlowTraceCore/Store/Store+Screenshots.swift`, `Sources/FlowTraceCore/Search/SearchIndex.swift`, `Sources/FlowTraceTests/ScreenshotTests.swift`, `Sources/FlowTraceTests/main.swift`.

- [ ] Write a failing disposable-database test for save, retrieval, search by OCR and description, description edits/reindex, OCR retry/reindex, deletion, full-data deletion, and persistence after reopen.
- [ ] Add a screenshot table and model with image bytes, MIME type, OCR status/text, description, and timestamp.
- [ ] Make save, edit, OCR retry, and delete update FTS5 in the same database transaction.
- [ ] Run the screenshot tests, then the full suite; commit.

### Task 2: OCR and bounded image conversion

**Files:** `Sources/FlowTraceCore/Screenshots/ScreenshotImageProcessor.swift`, `Sources/FlowTraceTests/ScreenshotTests.swift`.

- [ ] Accept image bytes from either future clipboard or file callers, reject unreadable inputs, cap input bytes and decoded pixels before rasterization, normalize to bounded JPEG data without source metadata.
- [ ] Implement Vision text recognition in FlowTraceCore so the existing test runner can exercise it. Preserve the image when OCR fails and expose a retry API; Task 3 invokes it off the main thread from the app.
- [ ] Verify a synthetic text image is searchable after processing in FlowTraceTests; commit.

### Task 3: Usable screenshot library

**Files:** `Sources/FlowTraceApp/Screenshots/ScreenshotImportController.swift`, `Sources/FlowTraceApp/Screenshots/ScreenshotLibraryView.swift`, `Sources/FlowTraceApp/Screenshots/ScreenshotDetailView.swift`, `Sources/FlowTraceApp/AppModel.swift`, `Sources/FlowTraceApp/FlowTraceApp.swift`, `Sources/FlowTraceApp/Shell/AppSidebar.swift`, `Sources/FlowTraceApp/Dashboard/SearchResultsView.swift`.

- [ ] Add a first-class Screenshots navigation item and clear import/paste actions; bridge clipboard/file reads to Core processing off the main thread.
- [ ] Show a metadata-only paged gallery with bounded thumbnail loading, local search state, empty/error states, and full image detail with description edit, OCR retry, and delete. Global search hits open screenshot detail.
- [ ] Confirm the new flow in a disposable-profile app; commit.

### Task 4: Data rights and release truth

**Files:** `Sources/FlowTraceCore/Store/Store+Export.swift`, `Sources/FlowTraceApp/Settings/SettingsView.swift`, `README.md`, `PRODUCT_AUDIT.md`, `launch-checklist-flowtrace.md`.

- [ ] Include screenshot images and metadata in JSON export without blocking the UI; query only screenshot metadata for Markdown export and explain its text-only format.
- [ ] Count screenshots in Settings holdings and verify its empty-state copy.
- [ ] Verify Delete all data also removes screenshot bytes and index text.
- [ ] Update product copy to describe deliberate screenshot saving, not background recording.
- [ ] Run full tests, debug/release app builds, archive checks, review, and raise a PR.
