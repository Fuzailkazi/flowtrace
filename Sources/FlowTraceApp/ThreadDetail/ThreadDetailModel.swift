import Foundation
import SwiftUI
import FlowTraceCore

/// Everything the thread detail screen shows, and every action it can take.
///
/// The view renders this and nothing else — no database calls, no git probes, no
/// summarising in the view body. That split is what keeps the detail screen
/// readable and lets each piece be reasoned about on its own.
@MainActor
@Observable
final class ThreadDetailModel {
    private let app: AppModel
    private(set) var threadId: String

    private(set) var tabs: [BrowserContext] = []
    private(set) var code: [CodeContext] = []
    private(set) var notes: [Note] = []
    private(set) var timeline: [TimelineEvent] = []

    /// What moved in each linked repository since it was captured, keyed by path.
    private(set) var repoChanges: [String: RepoChange] = [:]

    /// Set only when the user asks for a summary; cleared when they dismiss it.
    var summary: ThreadSummary?

    init(app: AppModel, threadId: String) {
        self.app = app
        self.threadId = threadId
    }

    // MARK: - Loading

    func load(threadId: String? = nil) {
        if let threadId { self.threadId = threadId }
        let store = app.store
        let id = self.threadId

        tabs = (try? store.tabs(threadId: id)) ?? []
        code = (try? store.codeContexts(threadId: id)) ?? []
        notes = (try? store.notes(threadId: id)) ?? []
        timeline = (try? store.timeline(threadId: id)) ?? []
        refreshRepoChanges()
    }

    /// Compares each linked repository's stored snapshot against its state right
    /// now — this is what answers "what changed since I last worked on it?".
    ///
    /// Probing shells out to git once per repository, so it runs off the main
    /// actor and the screen renders without waiting for it.
    private func refreshRepoChanges() {
        let contexts = code
        let store = app.store

        Task.detached(priority: .utility) {
            let probe = GitProbe()
            var changes: [String: RepoChange] = [:]
            for context in contexts {
                guard let state = probe.probe(context.repositoryPath) else { continue }
                if let change = try? store.change(
                    for: context.repositoryPath, against: state.snapshot()
                ) {
                    changes[context.repositoryPath] = change
                }
            }
            await MainActor.run { [weak self] in self?.repoChanges = changes }
        }
    }

    // MARK: - Summary

    /// Builds the summary from what is loaded here and nothing else, so every
    /// line in it traces back to a record the user can open.
    func summarize(_ thread: WorkThread) {
        let changesByRepositoryName = repoChanges.compactMap { path, change in
            code.first { $0.repositoryPath == path }.map { ($0.repositoryName, change) }
        }

        summary = DeterministicSummarizer().summarize(SummaryInput(
            thread: thread,
            tabs: tabs,
            code: code,
            notes: notes,
            timeline: timeline,
            repoChanges: Dictionary(uniqueKeysWithValues: changesByRepositoryName)
        ))
    }

    // MARK: - Mutations

    func addNote(_ content: String, isDecision: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try app.store.addNote(Note(
                workThreadId: threadId, content: trimmed, isDecision: isDecision
            ))
            reload()
        } catch {
            app.toast = Toast(
                message: "Couldn't add that note: \(error.localizedDescription)", isError: true
            )
        }
    }

    func deleteNote(id: String) {
        try? app.store.deleteNote(id: id)
        load()
    }

    func removeTab(id: String) {
        try? app.store.removeTab(id: id)
        reload()
    }

    func removeCode(id: String) {
        try? app.store.removeCode(id: id)
        reload()
    }

    /// Refreshes both this screen and the surrounding dashboard, which shows
    /// link counts that any of these mutations can change.
    private func reload() {
        app.refresh()
        load()
    }
}
