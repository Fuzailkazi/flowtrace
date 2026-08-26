import SwiftUI
import FlowTraceCore

/// A single Work Thread: why it exists, what's next, and everything linked to it.
///
/// Presentation only. Loading, git probing and summarising live in
/// `ThreadDetailModel`; the sections themselves are in ThreadDetailSections.swift.
struct ThreadDetailView: View {
    @Bindable var model: AppModel
    let thread: WorkThread

    @State var detail: ThreadDetailModel
    @State private var editing = false
    @State private var draft = WorkThread(title: "")
    @State private var draftTags = ""
    @State private var showingCapture = false

    // Draft state for the notes composer, rendered in ThreadDetailSections.swift.
    @State var draftNote = ""
    @State var noteIsDecision = false

    init(model: AppModel, thread: WorkThread) {
        self.model = model
        self.thread = thread
        _detail = State(initialValue: ThreadDetailModel(app: model, threadId: thread.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if editing { editor } else { fields }
                if let summary = detail.summary { summaryCard(summary) }
                linkedRepositories
                linkedTabs
                notesSection
                timelineSection
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle(thread.title)
        .toolbar {
            ToolbarItemGroup {
                Button("Resume") { model.resume(thread.id) }
                Button {
                    showingCapture = true
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                Menu {
                    Button(editing ? "Stop editing" : "Edit fields") {
                        if !editing {
                            draft = thread
                            draftTags = thread.tags.joined(separator: ", ")
                        }
                        editing.toggle()
                    }
                    Button("Summarize context") { detail.summarize(thread) }
                    Divider()
                    if thread.status != .paused {
                        Button("Mark paused") { model.setStatus(.paused, for: thread.id) }
                    }
                    if thread.status != .completed {
                        Button("Mark completed") { model.setStatus(.completed, for: thread.id) }
                    } else {
                        Button("Reopen") { model.setStatus(.active, for: thread.id) }
                    }
                    Divider()
                    Button("Delete thread", role: .destructive) { model.delete(threadId: thread.id) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingCapture) {
            CaptureSheet(model: model, presetThreadId: thread.id)
        }
        .task(id: thread.id) { detail.load(threadId: thread.id) }
        .onChange(of: model.threads) { _, _ in detail.load() }
    }

    // MARK: - Header and fields

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                StatusDot(status: thread.status, blocked: thread.isBlocked)
                Text(thread.title).font(.system(size: 20, weight: .semibold))
                if thread.origin == .detected {
                    Chip(text: "detected", color: .purple, systemImage: "sparkle")
                }
                Chip(text: thread.priority.label, color: Theme.priorityColor(thread.priority))
            }
            HStack(spacing: Theme.Space.m) {
                Text("Created \(thread.createdAt.relativeShort)")
                Text("Updated \(thread.updatedAt.relativeShort)")
                if let resumed = thread.lastResumedAt {
                    Text("Resumed \(resumed.relativeShort)")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)

            if !thread.tags.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(thread.tags, id: \.self) { Chip(text: $0) }
                }
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            field("Why am I doing this?", thread.intent, placeholder: "No intent recorded yet.")
            field("What should I do next?", thread.nextStep,
                  placeholder: "No next step recorded.", emphasised: true)
            if thread.isBlocked {
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        FieldLabel(text: "Blocked by")
                        Text(thread.blocker ?? "").font(.system(size: 13)).foregroundStyle(.red)
                    }
                }
            }
            if !thread.description.isEmpty {
                field("Description", thread.description, placeholder: "")
            }
        }
    }

    private func field(
        _ label: String, _ value: String, placeholder: String, emphasised: Bool = false
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(text: label)
                Text(value.isEmpty ? placeholder : value)
                    .font(.system(size: 13, weight: emphasised ? .medium : .regular))
                    .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
            }
        }
    }

    private var editor: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                LabeledField("Title", text: $draft.title)
                LabeledField("Why am I doing this?", text: $draft.intent, axis: .vertical)
                LabeledField("What should I do next?", text: $draft.nextStep, axis: .vertical)
                LabeledField("Blocker", text: Binding(
                    get: { draft.blocker ?? "" },
                    set: { draft.blocker = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                LabeledField("Tags (comma separated)", text: $draftTags)

                HStack(spacing: Theme.Space.m) {
                    Picker("Status", selection: $draft.status) {
                        ForEach(ThreadStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 180)
                    Picker("Priority", selection: $draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 180)
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        var edited = draft
                        edited.tags = draftTags
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        model.update(edited, announce: "Saved")
                        editing = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Summary

    private func summaryCard(_ summary: ThreadSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    FieldLabel(text: "Context summary")
                    Spacer()
                    Button("Dismiss") { detail.summary = nil }
                        .buttonStyle(.link).font(.system(size: 10))
                }
                Text(summary.about).font(.system(size: 12))

                if !summary.recently.isEmpty {
                    FieldLabel(text: "Recently")
                    ForEach(summary.recently, id: \.self) { line in
                        Text("• \(line)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if !summary.importantItems.isEmpty {
                    FieldLabel(text: "Linked items that matter")
                    ForEach(summary.importantItems, id: \.self) { line in
                        Text("• \(line)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                FieldLabel(text: "Likely next step")
                Text(summary.likelyNextStep).font(.system(size: 12, weight: .medium))

                // Always state the basis. The user should never have to guess
                // what a summary was built from.
                Text(summary.basedOn)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.Space.xs)
            }
        }
    }

}
