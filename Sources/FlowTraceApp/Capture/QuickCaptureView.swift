import SwiftUI
import AppKit
import FlowTraceCore

/// "Why am I here?" — answered in one line, without leaving the page you're on.
///
/// The whole interaction is: press the key, glance at what it already knows,
/// type a few words, press Return. Anything longer and the person who forgets
/// things won't do it.
struct QuickCaptureView: View {
    @Bindable var model: AppModel
    let snapshot: FrontmostSnapshot
    let onFinish: () -> Void

    @State private var resolved: FrontmostSnapshot
    @State private var note = ""
    @State private var threadId: String?
    @State private var saved = false
    @FocusState private var focused: Bool

    init(model: AppModel, snapshot: FrontmostSnapshot, onFinish: @escaping () -> Void) {
        self.model = model
        self.snapshot = snapshot
        self.onFinish = onFinish
        _resolved = State(initialValue: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            context
            Divider()
            if saved { confirmation } else { editor }
        }
        .padding(Theme.Space.l)
        .frame(width: 520, alignment: .leading)
        .background(.regularMaterial)
        .onAppear {
            threadId = model.continueWhereYouLeftOff.first?.id
            focused = true
            resolveTab()
        }
    }

    /// What FlowTrace already knows, so the user doesn't retype it.
    private var context: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: resolved.isBrowser ? "safari" : "app.dashed")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(resolved.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(resolved.appName)
                    if let detail = resolved.detail {
                        Text("·")
                        Text(detail)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Why are you here?", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(save)

            HStack(spacing: Theme.Space.s) {
                Picker("", selection: $threadId) {
                    Text("New thread").tag(String?.none)
                    ForEach(model.threads.filter { $0.status != .completed }) {
                        Text($0.title).tag(String?.some($0.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 240)

                Spacer()
                Text("esc to cancel")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: [])
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .background {
            // Escape dismisses without saving, from anywhere in the panel.
            Button("", action: onFinish)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        }
    }

    private var confirmation: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Saved to \(model.thread(id: threadId ?? "")?.title ?? "FlowTrace")")
                .font(.system(size: 13))
            Spacer()
        }
    }

    // MARK: - Actions

    /// Fills in the tab details a moment after the panel is already on screen,
    /// so AppleScript never delays it appearing.
    private func resolveTab() {
        let snapshot = self.snapshot
        Task.detached(priority: .userInitiated) {
            let enriched = snapshot.resolvingBrowserTab()
            await MainActor.run {
                if enriched != snapshot { resolved = enriched }
            }
        }
    }

    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            // The note IS the intent — it's the sentence you'd otherwise lose.
            let target = try resolveThread(intent: text)

            if let url = resolved.url, !url.isEmpty {
                _ = try model.store.attach(tabs: [
                    BrowserContext(
                        browser: resolved.appName,
                        pageTitle: resolved.pageTitle ?? url,
                        url: url,
                        note: text
                    ),
                ], to: target)
            } else {
                _ = try model.store.addNote(Note(
                    workThreadId: target,
                    content: "\(text)\n\n— in \(resolved.appName)"
                ))
            }

            threadId = target
            model.refresh()
            saved = true
            // Long enough to register, short enough not to be in the way.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                onFinish()
            }
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
            onFinish()
        }
    }

    private func resolveThread(intent: String) throws -> String {
        if let threadId, model.thread(id: threadId) != nil { return threadId }
        // No thread chosen: the note becomes a new one, titled by what you typed.
        let thread = try model.store.create(WorkThread(
            title: AgentSession.condense(intent, limit: 60),
            intent: intent
        ))
        return thread.id
    }
}
