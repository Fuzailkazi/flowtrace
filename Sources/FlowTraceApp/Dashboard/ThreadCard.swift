import SwiftUI
import FlowTraceCore

/// The card used everywhere a thread is listed.
///
/// It carries the answer to "what was I doing and what comes next" without
/// needing to be opened — title, intent, next step, what's linked, how cold.
struct ThreadCard: View {
    @Bindable var model: AppModel
    let thread: WorkThread
    var showResume = true

    private var counts: (tabs: Int, code: Int) { model.linkCounts(for: thread.id) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header

                if !thread.intent.isEmpty {
                    Text(thread.intent)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !thread.nextStep.isEmpty {
                    HStack(alignment: .top, spacing: Theme.Space.xs) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                        Text(thread.nextStep)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                    }
                }

                if let blocker = thread.blocker, !blocker.isEmpty {
                    HStack(alignment: .top, spacing: Theme.Space.xs) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .padding(.top, 2)
                        Text(blocker)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                footer
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.route = .thread(thread.id) }
        .contextMenu {
            Button("Open") { model.route = .thread(thread.id) }
            Button("Resume") { model.resume(thread.id) }
            Divider()
            if thread.status != .paused {
                Button("Pause") { model.setStatus(.paused, for: thread.id) }
            }
            if thread.status != .completed {
                Button("Mark completed") { model.setStatus(.completed, for: thread.id) }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(threadId: thread.id) }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            StatusDot(status: thread.status, blocked: thread.isBlocked)
            Text(thread.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if thread.origin == .detected {
                Chip(text: "detected", color: .purple, systemImage: "sparkle")
            }
            if thread.priority == .high {
                Chip(text: "high", color: .red)
            }
            Spacer(minLength: Theme.Space.s)
            if showResume {
                Button("Resume") { model.resume(thread.id) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            Label("\(counts.tabs)", systemImage: "safari")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(counts.tabs == 0 ? .tertiary : .secondary)
            Label("\(counts.code)", systemImage: "folder")
                .foregroundStyle(counts.code == 0 ? .tertiary : .secondary)

            ForEach(thread.tags.prefix(3), id: \.self) { tag in
                Chip(text: tag)
            }

            Spacer()
            Text(thread.lastActivityAt.relativeShort)
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
    }
}

/// A proposal card. Its whole job is to show the evidence, so the user can judge
/// it without trusting FlowTrace.
struct ProposalCard: View {
    @Bindable var model: AppModel
    let proposal: ThreadProposal
    @State private var isEditing = false
    @State private var title = ""
    @State private var intent = ""
    @State private var nextStep = ""

    private var evidence: DetectionEvidence { proposal.evidence }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Text(isEditing ? "Review before adding" : evidence.repositoryName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if !isEditing {
                        Chip(text: evidence.branch, color: .blue)
                    }
                    Spacer()
                    Text("you stopped \(evidence.daysSinceLastCommit)d ago")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.heatColor(days: evidence.daysSinceLastCommit))
                }

                // Everything below is what you were actually doing. Counts and
                // staleness go last, because they never told you what a thing was.
                if !isEditing {
                    if let was = evidence.sessionTitle {
                        detailRow("was", was, weight: .medium)
                    }
                    if let files = evidence.fileSummary {
                        detailRow("editing", files, mono: true)
                    }
                    if let subject = evidence.lastCommitSubject {
                        detailRow("last landed", subject)
                    }

                    if !evidence.promptArc.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(evidence.promptArc, id: \.self) { prompt in
                                HStack(alignment: .top, spacing: 5) {
                                    Text("·").foregroundStyle(.tertiary)
                                    Text(prompt)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.top, 1)
                    }

                    HStack(spacing: Theme.Space.xs) {
                        if evidence.dirtyFileCount > 0 {
                            Chip(text: "\(evidence.dirtyFileCount) uncommitted", color: .orange)
                        }
                        if evidence.unpushedCommitCount > 0 {
                            Chip(text: "\(evidence.unpushedCommitCount) unpushed", color: .orange)
                        }
                        ForEach(evidence.agents, id: \.self) { agent in
                            Chip(text: agent.label, color: .purple)
                        }
                    }
                }

                if isEditing {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        LabeledField("Title", text: $title)
                        LabeledField("Why am I doing this?", text: $intent, axis: .vertical)
                        LabeledField("What should I do next?", text: $nextStep, axis: .vertical)
                    }
                    .padding(.top, Theme.Space.xs)
                } else {
                    Text(evidence.repositoryPath.abbreviatingHome)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: Theme.Space.s) {
                    if isEditing {
                        Button("Add thread") {
                            model.accept(proposal, edited: (title, intent, nextStep))
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Cancel") { isEditing = false }
                    } else {
                        Button("Add thread") { model.accept(proposal, edited: nil) }
                            .buttonStyle(.borderedProminent)
                        Button("Edit first") {
                            title = proposal.suggestedTitle
                            intent = proposal.suggestedIntent
                            nextStep = proposal.suggestedNextStep
                            isEditing = true
                        }
                        Spacer()
                        Menu("Dismiss") {
                            Button("Not right now") { model.dismiss(proposal) }
                            Button("Never suggest \(evidence.repositoryName)") {
                                model.dismiss(proposal, ignoreRepository: true)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .controlSize(.small)
                .padding(.top, Theme.Space.xs)
            }
        }
    }


    /// A labelled line of context: a quiet label, then the thing itself.
    private func detailRow(
        _ label: String, _ value: String,
        mono: Bool = false, weight: Font.Weight = .regular
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, weight: weight, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

}

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var axis: Axis = .horizontal

    init(_ label: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.label = label
        self._text = text
        self.axis = axis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FieldLabel(text: label)
            if axis == .vertical {
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
    }
}
