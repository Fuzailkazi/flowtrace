import Foundation
import FlowTraceCore

// Fixtures are committed alongside the suite. Tests never read the user's real
// ~/.claude or ~/.codex directories.
let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

runAdapterTests(fixtures: fixtures)
runStoreTests()
runSearchTests()
runDetectorTests()
runSummaryTests()
runBrowserTests()
runServerTests()
runCORSTests()
runBriefTests()
runActivityTests()


TestKit.summarize()
