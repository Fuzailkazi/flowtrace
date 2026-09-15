import Foundation
import FlowTraceCore

/// Opening something you forgot, and getting an answer you can trust.
///
/// The screen makes one promise beyond showing context: it says where each
/// piece came from, and it says out loud what it could not find. Most of these
/// tests are about the second half, because a blank space reads as "there was
/// nothing here" and that is a different claim from "nobody looked".
func runRecallTests() {
    TestKit.suite("What was I doing here")

    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("flowtrace-recall-\(UUID().uuidString)")
    let manager = FileManager.default
    try? manager.createDirectory(at: scratch, withIntermediateDirectories: true)

    func note(building: String = "", nextStep: String = "", paused: Bool = false) -> ProjectNote {
        var note = ProjectNote(repositoryPath: scratch.path, repositoryName: "acme")
        note.building = building
        note.nextStep = nextStep
        note.isPaused = paused
        return note
    }

    func brief(title: String? = nil, prompts: [String] = []) -> ResumeBrief {
        ResumeBrief(
            repositoryName: "acme", repositoryPath: scratch.path, branch: "main",
            daysSinceActivity: 1, hoursSinceActivity: 20,
            recentPrompts: prompts, sessionTitle: title
        )
    }

    func liveAgent(_ prompt: String?, state: LiveAgent.State = .forgotten) -> LiveProject {
        LiveProject(
            path: scratch.path, name: "acme",
            agents: [LiveAgent(
                pid: 1, agent: .claudeCode, workingDirectory: scratch.path,
                projectRoot: scratch.path, repositoryName: "acme",
                lastPrompt: prompt, lastActivityAt: Date().addingTimeInterval(-70_000),
                state: state
            )],
            servers: []
        )
    }

    TestKit.suite("Which answer leads")

    // The ordering is a claim about trust, not about recency. A sentence the
    // user wrote themselves is the only line in the system that was authored
    // rather than inferred, so nothing outranks it.
    TestKit.test("what you wrote yourself beats everything FlowTrace worked out") {
        let recall = PlaceRecall(
            path: scratch.path, name: "acme",
            brief: brief(title: "Refactoring the importer", prompts: ["fix the flaky test"]),
            note: note(building: "the billing rewrite"),
            live: liveAgent("something else entirely")
        )
        expectEqual(recall.intent?.text, "the billing rewrite")
        expectEqual(recall.intent?.source, .youWroteThis)
        expectEqual(recall.intent?.source.attribution, "you wrote this")
    }

    TestKit.test("the agent's own session title comes next") {
        let recall = PlaceRecall(
            path: scratch.path, name: "acme",
            brief: brief(title: "Refactoring the importer", prompts: ["fix the flaky test"])
        )
        expectEqual(recall.intent?.text, "Refactoring the importer")
        expectEqual(recall.intent?.source, .theAgentTitledIt)
    }

    TestKit.test("then the last thing you actually typed") {
        let recall = PlaceRecall(
            path: scratch.path, name: "acme",
            brief: brief(prompts: ["first thing", "fix the flaky test"])
        )
        expectEqual(recall.intent?.text, "fix the flaky test", "the last, not the first")
        expectEqual(recall.intent?.source, .theLastThingYouAsked)
    }

    TestKit.test("a live prompt answers when there is no brief at all") {
        let recall = PlaceRecall(path: scratch.path, name: "acme", live: liveAgent("add rate limiting"))
        expectEqual(recall.intent?.text, "add rate limiting")
    }

    // Better a blank than a sentence nobody wrote.
    TestKit.test("with nothing recorded, nothing is invented") {
        let recall = PlaceRecall(path: scratch.path, name: "acme")
        expect(recall.intent == nil)
        expect(!recall.hasSomethingToSay)
    }

    TestKit.test("an empty note does not take the top slot from a real title") {
        let recall = PlaceRecall(
            path: scratch.path, name: "acme",
            brief: brief(title: "Refactoring the importer"), note: note(building: "")
        )
        expectEqual(recall.intent?.source, .theAgentTitledIt)
    }

    TestKit.suite("Your own words")

    TestKit.test("a next step is shown only when you wrote one") {
        expectEqual(
            PlaceRecall(path: scratch.path, name: "acme", note: note(nextStep: "wire up the webhook"))
                .nextStep,
            "wire up the webhook"
        )
        // FlowTrace does not decide what somebody's next step is.
        expect(PlaceRecall(
            path: scratch.path, name: "acme",
            brief: brief(prompts: ["fix the flaky test"])
        ).nextStep == nil)
    }

    TestKit.test("work you parked is not handed back to you as forgotten") {
        let paused = PlaceRecall(
            path: scratch.path, name: "acme", note: note(building: "x", paused: true),
            live: liveAgent(nil)
        )
        expect(paused.isPaused)
        expect(!PlaceRecall(path: scratch.path, name: "acme", live: liveAgent(nil)).isPaused)
    }

    TestKit.suite("Saying what is missing")

    let builder = PlaceRecallBuilder()

    TestKit.test("a folder that no longer exists says so and stops") {
        let recall = builder.build(
            path: "/nowhere/at/all", name: "ghost", sources: .all
        )
        expectEqual(recall.gaps, [.placeIsGone])
        expect(recall.git == nil, "nothing was read from a path that is not there")
        expect(recall.brief == nil)
    }

    TestKit.test("a plain folder says it is not a repository") {
        let recall = builder.build(path: scratch.path, name: "acme", sources: .all)
        expect(recall.gaps.contains(.notARepository))
    }

    // The consent boundary. With nothing switched on the brief is not built at
    // all, so no transcript is opened, and the screen says why rather than
    // showing an empty section that looks like tidy work.
    TestKit.test("with no source switched on, no transcript is opened and the screen says so") {
        let recall = builder.build(path: scratch.path, name: "acme", sources: .none)
        expect(recall.gaps.contains(.transcriptsNotAllowed))
        expect(recall.brief == nil, "the brief is what opens transcripts, so it is not built")
        expect(!recall.gaps.contains(.noSessionsFound),
               "never claims nothing was found when nothing was looked at")
    }

    TestKit.test("a note you wrote is still yours to read without any source switched on") {
        let recall = builder.build(
            path: scratch.path, name: "acme", sources: .none, note: note(building: "the billing rewrite")
        )
        expectEqual(recall.intent?.text, "the billing rewrite")
        expectEqual(recall.intent?.source, .youWroteThis, "your own words need nobody's permission")
    }

    // The sentence shown where the answer should be. Saying "nothing recorded"
    // when nobody looked tells the user their work left no trace, which is both
    // false and the opposite of the consent promise.
    TestKit.test("an unread place is never told it left no trace") {
        let unread = builder.build(path: scratch.path, name: "acme", sources: .none)
        expect(unread.intentAbsence.contains("hasn't read"), "got: \(unread.intentAbsence)")
        expect(!unread.intentAbsence.contains("nothing recorded"))

        let looked = PlaceRecall(path: scratch.path, name: "acme", gaps: [.noSessionsFound])
        expect(looked.intentAbsence.contains("nothing recorded"), "got: \(looked.intentAbsence)")

        let gone = PlaceRecall(path: "/nowhere", name: "ghost", gaps: [.placeIsGone])
        expect(gone.intentAbsence.contains("gone"))
    }

    TestKit.test("every gap can be explained to a person") {
        for gap in PlaceRecall.Gap.allCases {
            expect(!gap.explanation.isEmpty, "\(gap.rawValue) has nothing to say")
            expect(gap.explanation.hasSuffix("."), "\(gap.rawValue) is not a sentence")
        }
    }

    TestKit.suite("More than one possible answer")

    // Two agents in one place, each with its own last prompt. The screen shows
    // the place's strongest signal rather than picking a winner silently.
    TestKit.test("two agents in one place do not silently collapse to one story") {
        let project = LiveProject(
            path: scratch.path, name: "acme",
            agents: [
                LiveAgent(
                    pid: 1, agent: .claudeCode, workingDirectory: scratch.path,
                    projectRoot: scratch.path, repositoryName: "acme",
                    lastPrompt: "older question",
                    lastActivityAt: Date().addingTimeInterval(-90_000), state: .forgotten
                ),
                LiveAgent(
                    pid: 2, agent: .codex, workingDirectory: scratch.path,
                    projectRoot: scratch.path, repositoryName: "acme",
                    lastPrompt: "newer question",
                    lastActivityAt: Date().addingTimeInterval(-70_000), state: .forgotten
                ),
            ],
            servers: []
        )
        expectEqual(project.lastPrompt, "newer question", "the most recent of the two")
        expectEqual(project.agents.count, 2, "both are still there to be seen")
    }

    TestKit.test("an unread agent contributes no story at all") {
        let hidden = LiveProject(
            path: scratch.path, name: "acme",
            agents: [LiveAgent(
                pid: 1, agent: .claudeCode, workingDirectory: scratch.path,
                projectRoot: scratch.path, repositoryName: "acme",
                state: .forgotten, transcriptHidden: true
            )],
            servers: []
        )
        let recall = PlaceRecall(path: scratch.path, name: "acme", live: hidden)
        expect(recall.intent == nil, "nothing was read, so nothing is quoted")
    }

    TestKit.suite("Getting back to work")

    // The handoff is the same text the command line gives an agent. If it stops
    // rendering, the recovery button copies an empty string and the user finds
    // out by pasting it.
    TestKit.test("the handoff text names the place and what was happening") {
        let text = brief(title: "Refactoring the importer", prompts: ["fix the flaky test"]).render()
        expect(text.contains("acme"), "names the place")
        expect(text.contains("main"), "names the branch")
        expect(text.contains("Refactoring the importer"), "carries what the session was about")
        expect(!text.isEmpty)
    }

    TestKit.test("a place still holding a port is worth mentioning") {
        let project = LiveProject(
            path: scratch.path, name: "acme", agents: [],
            servers: [LiveServer(pid: 9, port: 3_000, processName: "node")]
        )
        expectEqual(project.servers.first?.address, "http://localhost:3000")
    }
}
