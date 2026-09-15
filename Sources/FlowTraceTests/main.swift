import Foundation
import FlowTraceCore

// Fixtures are committed alongside the suite. Tests never read the user's real
// ~/.claude or ~/.codex directories.
let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

// Deletion tests clear the diagnostics log. Point it at a scratch directory
// before anything runs, so a test never removes the real one.
Diagnostics.directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("flowtrace-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(
    at: Diagnostics.directory, withIntermediateDirectories: true
)

runAdapterTests(fixtures: fixtures)
runEditorPlaceTests(fixtures: fixtures)
runStoreTests()
runSearchTests()
runMemorySearchTests()
runDetectorTests()
runSummaryTests()
runBrowserTests()
runBrowserContextTests()
runTabNoteTests()
runPaletteTests()
runServerTests()
runCORSTests()
runBriefTests()
runCaptureSuggesterTests()
runCaptureTargetingTests()
runDraggedPathTests()
runActivityTests()
runSessionImportTests()
runLiveProjectTests()
runDeletionTests()
runWrittenOnlyTests()
runErasureTests()
runMemoriesTests()
runHoldingsSizeTests()
runRecorderPipelineTests()
runPrivacyTests()
runRedactionFixtureTests(fixtures: fixtures)
runNowTests()
runAssociationTests(fixtures: fixtures)
runOpenCodeTests()
runNowOrderingTests()
runAttentionTests()
runHandoffTests()
runWorkspaceWindowTests()
runScheduledTaskTests(fixtures: fixtures)
runRecallTests()
runContextualCaptureTests(
    repositoryRoot: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // FlowTraceTests
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // repository root
)
runConsentTests(fixtures: fixtures)


TestKit.summarize()
