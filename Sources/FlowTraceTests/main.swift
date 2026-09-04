import Foundation
import FlowTraceCore

// Fixtures are committed alongside the suite. Tests never read the user's real
// ~/.claude or ~/.codex directories.
let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

runAdapterTests(fixtures: fixtures)
runEditorPlaceTests(fixtures: fixtures)
runStoreTests()
runSearchTests()
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


TestKit.summarize()
