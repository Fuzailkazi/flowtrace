import Foundation
import FlowTraceCore

func runCaptureSuggesterTests() {
    TestKit.suite("CaptureSuggester")

    TestKit.test("project note wins when all three sources are present") {
        let input = CaptureSuggestionInput(
            projectNote: "shipping the oauth refresh flow",
            tabNote: "reading about oauth pkce",
            lastAgentPrompt: "add refresh token rotation"
        )
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.text, "shipping the oauth refresh flow")
        expectEqual(suggestion.source, .projectNote)
    }

    TestKit.test("tab note wins over the last agent prompt when there is no project note") {
        let input = CaptureSuggestionInput(
            tabNote: "reading about oauth pkce",
            lastAgentPrompt: "add refresh token rotation"
        )
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.text, "reading about oauth pkce")
        expectEqual(suggestion.source, .tabNote)
    }

    TestKit.test("falls back to the last agent prompt alone") {
        let input = CaptureSuggestionInput(lastAgentPrompt: "add refresh token rotation")
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.text, "add refresh token rotation")
        expectEqual(suggestion.source, .agentPrompt)
    }

    // A note that exists but is blank (or whitespace) is the same as no note —
    // the source shouldn't win just because the field happens to be non-nil.
    TestKit.test("an empty or whitespace-only source is treated as absent") {
        let input = CaptureSuggestionInput(
            projectNote: "",
            tabNote: "   ",
            lastAgentPrompt: "add refresh token rotation"
        )
        let suggestion = try unwrap(CaptureSuggester.suggest(input))
        expectEqual(suggestion.source, .agentPrompt)
    }

    TestKit.test("no suggestion when nothing is available") {
        expectNil(CaptureSuggester.suggest(CaptureSuggestionInput()))
    }
}
