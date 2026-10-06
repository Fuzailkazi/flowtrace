import Foundation

/// Everything FlowTrace can honestly say about one place, assembled for
/// somebody who has just been told they forgot it.
///
/// Nothing here is new evidence. `BriefBuilder` already knew how to answer
/// "where was this repository left" — it was written for the command line and
/// for handing to an agent, and the app had no way to reach it. What this adds
/// is the part a person needs that an agent does not: the question of whether
/// the answer can be trusted, stated in the answer itself.
///
/// So each piece of context carries how it was found. A brief that came back
/// empty is not the same as a repository with nothing outstanding, and a
/// missing note is not the same as a note that says the work is paused. The
/// recovery screen shows the difference rather than flattening it into blanks.
public struct PlaceRecall: Sendable {
    /// Where this is. Always known — it is what was opened.
    public var path: String
    public var name: String

    /// What git can see right now. Nil when the path is not a repository, or
    /// has been deleted since the reading that listed it.
    public var git: GitState?

    /// The assembled "where you left it", when there was enough to build one.
    public var brief: ResumeBrief?

    /// What the user themselves wrote here, which outranks everything FlowTrace
    /// inferred. A person's own sentence about what they were building is the
    /// best context in the system and the only one that cannot be wrong.
    public var note: ProjectNote?

    /// What is running here at this moment, if anything still is.
    public var live: LiveProject?

    /// Why a piece of context is absent. Shown to the user, because "FlowTrace
    /// did not look" and "there was nothing there" are different answers and
    /// only one of them means the work is tidy.
    public enum Gap: String, Sendable, CaseIterable {
        /// The directory is gone, so nothing can be read from it.
        case placeIsGone
        /// Not a git repository, so there is no branch and no loose ends.
        case notARepository
        /// FlowTrace was not allowed to open any agent's transcript.
        case transcriptsNotAllowed
        /// Allowed to look, but no usable handoff could be assembled.
        case noSessionsFound

        public var explanation: String {
            switch self {
            case .placeIsGone:
                "This folder is no longer on disk."
            case .notARepository:
                "Not a git repository, so there is no branch or uncommitted work to report."
            case .transcriptsNotAllowed:
                "You haven't switched on any agent here, so FlowTrace hasn't read what was asked."
            case .noSessionsFound:
                "FlowTrace could not build a recent handoff for this place."
            }
        }
    }

    public var gaps: [Gap]

    public init(
        path: String, name: String, git: GitState? = nil, brief: ResumeBrief? = nil,
        note: ProjectNote? = nil, live: LiveProject? = nil, gaps: [Gap] = []
    ) {
        self.path = path
        self.name = name
        self.git = git
        self.brief = brief
        self.note = note
        self.live = live
        self.gaps = gaps
    }

    // MARK: - What to lead with

    /// The one sentence that answers "what was I doing here".
    ///
    /// Ordered by how much the source is worth trusting rather than by how
    /// recent it is. What the user wrote themselves comes first, because it is
    /// the only line in the system that was authored rather than inferred. The
    /// agent's own session title comes next, then the last thing actually
    /// typed. Nil when there is nothing worth putting in that position — an
    /// invented sentence is worse than an honest blank.
    public var intent: Intent? {
        if let building = note?.building, !building.isEmpty {
            return Intent(text: building, source: .youWroteThis)
        }
        if let title = brief?.sessionTitle, !title.isEmpty {
            return Intent(text: title, source: .theAgentTitledIt)
        }
        if let prompt = brief?.recentPrompts.last, !prompt.isEmpty {
            return Intent(text: prompt, source: .theLastThingYouAsked)
        }
        if let prompt = live?.lastPrompt, !prompt.isEmpty {
            return Intent(text: prompt, source: .theLastThingYouAsked)
        }
        return nil
    }

    public struct Intent: Sendable, Equatable {
        public var text: String
        public var source: Source

        public enum Source: String, Sendable {
            case youWroteThis
            case theAgentTitledIt
            case theLastThingYouAsked

            /// Said in the interface, so the reader knows how much weight it
            /// carries without having to ask where it came from.
            public var attribution: String {
                switch self {
                case .youWroteThis: "you wrote this"
                case .theAgentTitledIt: "the agent called the session this"
                case .theLastThingYouAsked: "the last thing you asked here"
                }
            }
        }
    }

    /// The single most useful thing to do next, if there is an obvious one.
    ///
    /// Only what the user said themselves. FlowTrace does not decide what
    /// somebody's next step is.
    public var nextStep: String? {
        guard let step = note?.nextStep, !step.isEmpty else { return nil }
        return step
    }

    /// Context to paste into an agent when returning to this place.
    /// A note the person wrote leads; inferred history follows it. Notes can
    /// contain pasted credentials, so they go through the same redaction as
    /// transcript text before leaving FlowTrace on the clipboard.
    public var handoff: String? {
        var ownWords: [String] = []
        if let building = safeNoteLine(note?.building) {
            ownWords.append("You wrote that you were building: \(building)")
        }
        if let step = safeNoteLine(note?.nextStep) {
            ownWords.append("You wrote the next step: \(step)")
        }
        let livePrompt = brief == nil ? safeNoteLine(live?.lastPrompt) : nil
        guard !ownWords.isEmpty || brief != nil || livePrompt != nil else { return nil }

        var sections = ["Repository: \(name) (\(path))"]
        if !ownWords.isEmpty { sections.append(ownWords.joined(separator: "\n")) }
        if let brief { sections.append(brief.render()) }
        if let livePrompt { sections.append("Last observed agent prompt: \(livePrompt)") }
        return sections.joined(separator: "\n\n")
    }

    private func safeNoteLine(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let redacted = Redaction.redact(text)
        guard !redacted.isEmpty, !Redaction.isOnlyRedactions(redacted) else { return nil }
        return AgentSession.condense(redacted.text, limit: 300)
    }

    /// True when the user marked this place as deliberately parked. It stops
    /// the screen calling paused work "forgotten" back at them.
    public var isPaused: Bool { note?.isPaused == true }

    /// What to say in place of the intent when there is no intent.
    ///
    /// "Nothing is recorded" and "nothing was read" are different sentences and
    /// the difference is the whole consent promise. Getting this wrong tells a
    /// user their work left no trace when in fact FlowTrace was never allowed
    /// to look for one.
    public var intentAbsence: String {
        if gaps.contains(.transcriptsNotAllowed) {
            return "FlowTrace hasn't read agent conversations here, so it can't say what this was for."
        }
        if gaps.contains(.placeIsGone) {
            return "This folder is gone, so there is nothing left to read."
        }
        return "FlowTrace has nothing recorded about what this was for."
    }

    /// Whether there is enough here to be worth reading at all.
    public var hasSomethingToSay: Bool {
        intent != nil || brief != nil || git?.isDirty == true || live?.agents.isEmpty == false
    }
}

/// Assembles a `PlaceRecall` for one path.
///
/// Every read here already existed somewhere in FlowTrace. What this does is
/// call them in one place, with the permission passed in, and record what it
/// could not find instead of returning a half-empty value that reads as a tidy
/// repository.
public struct PlaceRecallBuilder: Sendable {
    private let git: GitProbe
    private let briefs: BriefBuilder

    public init(git: GitProbe = GitProbe(), briefs: BriefBuilder = BriefBuilder()) {
        self.git = git
        self.briefs = briefs
    }

    public func build(
        path: String,
        name: String,
        sources: AgentSources,
        note: ProjectNote? = nil,
        live: LiveProject? = nil,
        config: BriefConfig = BriefConfig()
    ) -> PlaceRecall {
        var recall = PlaceRecall(path: path, name: name, note: note, live: live)

        guard FileManager.default.fileExists(atPath: path) else {
            recall.gaps = [.placeIsGone]
            return recall
        }

        recall.git = git.probe(path)
        if recall.git == nil { recall.gaps.append(.notARepository) }

        // The brief is what opens a transcript, so it is the only part gated on
        // consent — and with nothing switched on it is not called at all.
        guard sources != .none else {
            recall.gaps.append(.transcriptsNotAllowed)
            return recall
        }

        // The brief stays silent about a repository somebody was in an hour
        // ago, which is right for an unprompted nudge and wrong here: the user
        // opened this themselves and is owed an answer. So the quiet window is
        // removed for this call only.
        var opened = config
        opened.quietHours = 0

        recall.brief = briefs.build(repositoryPath: path, sources: sources, config: opened)
        if recall.brief == nil {
            // BriefBuilder can be silent for several reasons: no session,
            // stale work, no useful text, or a read failure. Git's last commit
            // cannot distinguish them, so the screen does not guess.
            recall.gaps.append(.noSessionsFound)
        }
        return recall
    }
}
