import SwiftUI
import FlowTraceCore

struct ThreadDetailView: View {
    @Bindable var model: AppModel
    let thread: WorkThread

    @State private var tabs: [BrowserContext] = []
    @State private var code: [CodeContext] = []
    @State private var notes: [Note] = []
    @State private var timeline: [TimelineEvent] = []
    @State private var repoChanges: [String: RepoChange] = [:]
    @State private var summary: ThreadSummary?

    @State private var draftNote = ""
    @State private var noteIsDecision = false
    @State private var editing = false
    @State private var draft = WorkThread(title: "")
    @State private var draftTags = ""
    @State private var showingCapture = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if editing { editor } else { fields }
                if let summary { summaryCard(summary) }
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
                    Button("Summarize context") { buildSummary() }
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
        .task(id: thread.id) { load() }
        .onChange(of: model.threads) { _, _ in load() }
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
                    Button("Dismiss") { self.summary = nil }
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

    // MARK: - Linked items

    @ViewBuilder
    private var linkedRepositories: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Repositories and sessions", count: code.count)
            if code.isEmpty {
                Card {
                    Text("Nothing attached. Use Attach, or run `flowtrace attach` in a repository.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(code) { context in
                    Card {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: Theme.Space.xs) {
                                    Text(context.repositoryName).font(.system(size: 13, weight: .medium))
                                    if let branch = context.branch {
                                        Chip(text: branch, color: .blue)
                                    }
                                    if let agent = context.agentName {
                                        Chip(text: agent.label, color: .purple)
                                    }
                                    if let sha = context.shortCommit {
                                        Chip(text: sha)
                                    }
                                }
                                Text(context.displayPath)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                if !context.note.isEmpty {
                                    Text(context.note).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                if let change = repoChanges[context.repositoryPath], !change.isEmpty {
                                    Text("Changed since you left — \(change.summaryLines.joined(separator: ", "))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            VStack(spacing: Theme.Space.xs) {
                                Button("Open") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: context.repositoryPath))
                                }
                                Button("Remove") { remove(code: context.id) }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var linkedTabs: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Browser tabs", count: tabs.count)
            if tabs.isEmpty {
                Card {
                    Text("No tabs attached yet.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(tabs) { tab in
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tab.pageTitle).font(.system(size: 12))
                                    Text(tab.url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary).lineLimit(1)
                                    if !tab.note.isEmpty {
                                        Text(tab.note).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(tab.capturedAt.relativeShort)
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                                Button("Open") {
                                    if let url = URL(string: tab.url) { NSWorkspace.shared.open(url) }
                                }
                                .buttonStyle(.link).font(.system(size: 10))
                                Button("Remove") { remove(tab: tab.id) }
                                    .buttonStyle(.link).font(.system(size: 10))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notes and timeline

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Notes and decisions", count: notes.count)
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    TextField("Add a note…", text: $draftNote, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    HStack {
                        Toggle("Record as a decision", isOn: $noteIsDecision)
                            .toggleStyle(.checkbox).font(.system(size: 11))
                        Spacer()
                        Button("Add note") { addNote() }
                            .controlSize(.small)
                            .disabled(draftNote.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            ForEach(notes) { note in
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if note.isDecision { Chip(text: "decision", color: .blue) }
                            Spacer()
                            Text(note.createdAt.relativeShort)
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Button("Delete") { deleteNote(note.id) }
                                .buttonStyle(.link).font(.system(size: 10))
                        }
                        Text(note.content).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Activity", count: timeline.count)
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(timeline) { event in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Circle().fill(Color.secondary.opacity(0.4))
                                .frame(width: 5, height: 5).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title).font(.system(size: 12, weight: .medium))
                                if !event.description.isEmpty {
                                    Text(event.description)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                            Spacer()
                            Text(event.createdAt.relativeShort)
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func load() {
        tabs = (try? model.store.tabs(threadId: thread.id)) ?? []
        code = (try? model.store.codeContexts(threadId: thread.id)) ?? []
        notes = (try? model.store.notes(threadId: thread.id)) ?? []
        timeline = (try? model.store.timeline(threadId: thread.id)) ?? []
        refreshRepoChanges()
    }

    /// Compares each linked repository's stored snapshot against its state right
    /// now, which is what answers "what changed since I last worked on it?".
    private func refreshRepoChanges() {
        let contexts = code
        let store = model.store
        Task.detached(priority: .utility) {
            let probe = GitProbe()
            var changes: [String: RepoChange] = [:]
            for context in contexts {
                guard let state = probe.probe(context.repositoryPath) else { continue }
                if let change = try? store.change(for: context.repositoryPath, against: state.snapshot()) {
                    changes[context.repositoryPath] = change
                }
            }
            await MainActor.run { repoChanges = changes }
        }
    }

    private func buildSummary() {
        summary = DeterministicSummarizer().summarize(SummaryInput(
            thread: thread, tabs: tabs, code: code, notes: notes,
            timeline: timeline,
            repoChanges: Dictionary(
                uniqueKeysWithValues: repoChanges.compactMap { path, change in
                    code.first { $0.repositoryPath == path }.map { ($0.repositoryName, change) }
                }
            )
        ))
    }

    private func addNote() {
        let content = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        do {
            _ = try model.store.addNote(Note(
                workThreadId: thread.id, content: content, isDecision: noteIsDecision
            ))
            draftNote = ""
            noteIsDecision = false
            model.refresh()
            load()
        } catch {
            model.toast = Toast(message: "Couldn't add that note: \(error.localizedDescription)", isError: true)
        }
    }

    private func deleteNote(_ id: String) {
        try? model.store.deleteNote(id: id)
        load()
    }

    private func remove(tab id: String) {
        try? model.store.removeTab(id: id)
        model.refresh()
        load()
    }

    private func remove(code id: String) {
        try? model.store.removeCode(id: id)
        model.refresh()
        load()
    }
}
