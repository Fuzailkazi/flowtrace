import SwiftUI
import AppKit
import FlowTraceCore

/// What you see when you open something you forgot.
///
/// The screen has one job and it is not reporting. Somebody has just been told
/// they left work running for two days; the question in their head is "what was
/// I doing here", and the answer has to arrive before anything else on the
/// page. So the order is fixed: the intent, then where it was left, then what
/// was being asked, then what FlowTrace could not find, and only then the
/// things you can do about it.
///
/// Nothing is shown because it exists. Process identifiers, file counts and
/// session identifiers are all available here and all absent, because none of
/// them answer the question.
struct PlaceRecallView: View {
    @Bindable var model: AppModel
    let path: String

    @State private var recall: PlaceRecall?
    @State private var loading = true
    @State private var building = ""
    @State private var nextStep = ""
    @State private var editing = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Journal.Space.xl) {
                backLink
                if loading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Journal.Space.section)
                } else if let recall {
                    heading(recall)
                    intentBlock(recall)
                    whereYouLeftIt(recall)
                    whatYouWereAsking(recall)
                    whatIsMissing(recall)
                    noteBlock(recall)
                    actions(recall)
                    captureHint
                }
            }
            .padding(Journal.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Journal.paper)
        .task(id: path) { load() }
    }

    // MARK: - Heading

    private var backLink: some View {
        Button {
            model.route = .now
        } label: {
            HStack(spacing: Journal.Space.xs) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text("Now").font(.caption())
            }
            .foregroundStyle(Journal.inkSoft)
        }
        .buttonStyle(.plain)
    }

    private func heading(_ recall: PlaceRecall) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            Text(recall.name)
                .font(.journalTitle(28))
                .foregroundStyle(Journal.ink)

            HStack(spacing: Journal.Space.s) {
                if recall.isPaused {
                    NowChip(text: "you paused this", symbol: "pause.circle")
                } else if let state = recall.live?.state {
                    NowChip(
                        // Said as of when it was read, once the reading is old
                        // enough that presenting it as "now" would be a claim
                        // rather than an observation.
                        text: model.census.isFresh
                            ? state.label
                            : "\(state.label) as of \(model.census.takenLabel ?? "earlier")",
                        symbol: state == .forgotten ? "moon.zzz" : "circle.fill",
                        tint: state == .forgotten ? Journal.amber : Journal.inkMid,
                        fill: state == .forgotten ? Journal.amberSoft : Journal.wash
                    )
                }
                Text(path.abbreviatingHome)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    // MARK: - The answer

    /// The sentence the page exists to deliver, with where it came from said
    /// plainly underneath. The attribution is not decoration: "you wrote this"
    /// and "the last thing you asked" deserve different amounts of trust, and
    /// hiding which one this is would make the good case and the guess look
    /// identical.
    private func intentBlock(_ recall: PlaceRecall) -> some View {
        Group {
            if let intent = recall.intent {
                VStack(alignment: .leading, spacing: Journal.Space.s) {
                    Text("“\(oneLine(intent.text))”")
                        .font(.journalTitle(19))
                        .foregroundStyle(Journal.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(intent.source.attribution)
                        .font(.caption())
                        .foregroundStyle(Journal.inkSoft)
                }
                .padding(Journal.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
            } else {
                Text(recall.intentAbsence)
                    .font(.observed(13))
                    .foregroundStyle(Journal.inkMid)
            }
        }
    }

    // MARK: - Where you left it

    private func whereYouLeftIt(_ recall: PlaceRecall) -> some View {
        Group {
            if !sentences(recall).isEmpty {
                VStack(alignment: .leading, spacing: Journal.Space.m) {
                    NowSectionHeader(symbol: "bookmark", title: "Where you left it")
                    VStack(alignment: .leading, spacing: Journal.Space.s) {
                        ForEach(sentences(recall), id: \.self) { line in
                            Text(line)
                                .font(.observed(13))
                                .foregroundStyle(Journal.inkMid)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Prose rather than fields. A branch name beside a number beside a count
    /// is a status readout; the same facts in sentences are a memory.
    private func sentences(_ recall: PlaceRecall) -> [String] {
        var lines: [String] = []

        if let brief = recall.brief {
            // The brief words this itself, because only it knows whether the
            // elapsed time can be attributed to a person or merely to a write.
            lines.append(brief.openingSentence)
        } else if let git = recall.git {
            lines.append("You're on branch \(git.branch).")
        }

        if let git = recall.git, git.dirtyFileCount > 0 {
            let names = recall.brief?.notableFiles ?? []
            let tail = names.isEmpty ? "." : " (\(names.joined(separator: ", ")))."
            lines.append("You left \(nowCount(git.dirtyFileCount, "file")) uncommitted\(tail)")
        }
        if let ahead = recall.git?.commitsAhead, ahead > 0 {
            lines.append("\(nowCount(ahead, "commit")) here never got pushed.")
        }
        if let subject = recall.git?.lastCommitSubject, !subject.isEmpty {
            lines.append("Your last commit was “\(oneLine(subject))”.")
        }
        // One line about what is still running, because a server still holding
        // a port is part of remembering — the list of ports is not.
        if let live = recall.live, !live.servers.isEmpty {
            let ports = live.servers.map { ":\($0.port)" }.joined(separator: ", ")
            lines.append("Something you started here is still listening on \(ports).")
        }
        return lines
    }

    // MARK: - What you were asking

    private func whatYouWereAsking(_ recall: PlaceRecall) -> some View {
        Group {
            if let prompts = recall.brief?.recentPrompts, !prompts.isEmpty {
                VStack(alignment: .leading, spacing: Journal.Space.m) {
                    NowSectionHeader(
                        symbol: "text.quote", title: "What you were asking",
                        trailing: "oldest first"
                    )
                    VStack(alignment: .leading, spacing: Journal.Space.s) {
                        ForEach(prompts, id: \.self) { prompt in
                            HStack(alignment: .top, spacing: Journal.Space.s) {
                                Text("·").foregroundStyle(Journal.inkSoft)
                                Text(oneLine(prompt))
                                    .font(.observed(13))
                                    .foregroundStyle(Journal.inkMid)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - What is missing

    /// Said out loud rather than left as an empty section. A blank space reads
    /// as "there was nothing here", which is a different and often wrong claim.
    private func whatIsMissing(_ recall: PlaceRecall) -> some View {
        Group {
            if !recall.gaps.isEmpty {
                VStack(alignment: .leading, spacing: Journal.Space.s) {
                    ForEach(recall.gaps, id: \.self) { gap in
                        HStack(alignment: .top, spacing: Journal.Space.s) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Journal.inkSoft)
                            Text(gap.explanation)
                                .font(.caption())
                                .foregroundStyle(Journal.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                            if gap == .transcriptsNotAllowed {
                                Button("Settings") { model.route = .settings }
                                    .buttonStyle(.link)
                                    .font(.caption())
                            }
                        }
                    }
                }
                .padding(Journal.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
            }
        }
    }

    // MARK: - Your own words

    private func noteBlock(_ recall: PlaceRecall) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            NowSectionHeader(symbol: "pencil.line", title: "Your own note")

            if editing {
                VStack(alignment: .leading, spacing: Journal.Space.s) {
                    TextField("what you're building here", text: $building)
                        .textFieldStyle(.plain)
                        .font(.observed(13))
                    Divider().overlay(Journal.rule)
                    TextField("what you'd do next", text: $nextStep)
                        .textFieldStyle(.plain)
                        .font(.observed(13))
                    HStack {
                        Spacer()
                        Button("Cancel") { editing = false }.buttonStyle(.plain)
                        Button("Save") { saveNote(recall) }.keyboardShortcut(.return)
                    }
                }
                .padding(Journal.Space.m)
                .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
            } else {
                Button { editing = true } label: {
                    VStack(alignment: .leading, spacing: Journal.Space.xs) {
                        if let step = recall.nextStep {
                            Text("Next: \(step)").font(.observed(13)).foregroundStyle(Journal.ink)
                        }
                        if recall.note?.building.isEmpty == false || recall.nextStep != nil {
                            Text("edit").font(.caption()).foregroundStyle(Journal.inkSoft)
                        } else {
                            Text("Say what you're building here, so next time you don't have to work it out.")
                                .font(.observed(13))
                                .foregroundStyle(Journal.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Journal.Space.m)
                    .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Getting back to work

    private func actions(_ recall: PlaceRecall) -> some View {
        HStack(spacing: Journal.Space.s) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            if let brief = recall.brief {
                // The same text the command line hands an agent. Copying it is
                // the shortest path from "I remember now" back to working.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(brief.render(), forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy handoff", systemImage: "doc.on.doc")
                }
            }
            Spacer()
        }
        .font(.caption())
        .padding(.top, Journal.Space.s)
    }

    // MARK: - Writing down why

    /// A line, not a field.
    ///
    /// The system earns the note rather than demanding it: having just been
    /// reminded what this place was, the user is the one moment they are able
    /// to say why they left. So the screen says how, once, and never asks
    /// again — there is no form here and nothing to dismiss.
    ///
    /// The key named is whatever the user configured. There is exactly one
    /// capture trigger in FlowTrace and this reads it, so changing it in
    /// Settings changes this sentence and the key that answers it together.
    private var captureHint: some View {
        HStack(spacing: Journal.Space.xs) {
            Text("Press")
            Text(model.captureTrigger.displayString)
                .font(.mono(11))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
            Text("to note why you left this — it will be filed here.")
        }
        .font(.caption())
        .foregroundStyle(Journal.inkSoft)
        .padding(.top, Journal.Space.s)
    }

    // MARK: - Data

    private func load() {
        loading = true
        let sources = model.readableSources
        let note = try? model.store.projectNote(for: path)
        // The reading Now already took, rather than a second one: taking our
        // own would cost the best part of a second and could disagree with the
        // row the user just clicked.
        let live = model.liveProject(at: path)
        let name = live?.name ?? SessionImporter.folderLabel(for: path)

        Task.detached(priority: .userInitiated) {
            let built = PlaceRecallBuilder().build(
                path: path, name: name, sources: sources, note: note, live: live
            )
            await MainActor.run {
                recall = built
                building = built.note?.building ?? ""
                nextStep = built.note?.nextStep ?? ""
                loading = false
            }
        }
    }

    private func saveNote(_ recall: PlaceRecall) {
        var note = recall.note ?? ProjectNote(repositoryPath: path, repositoryName: recall.name)
        note.building = building.trimmingCharacters(in: .whitespacesAndNewlines)
        note.nextStep = nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try model.store.saveProjectNote(note)
        } catch {
            model.toast = Toast(message: "Couldn't save that note. Your words are still here.", isError: true)
            return
        }
        editing = false
        load()
    }

    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
