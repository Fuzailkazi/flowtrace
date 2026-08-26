import SwiftUI
import FlowTraceCore

// Compact rows for a captured tab and a captured repository, shown on the
// dashboard and in Recent Captures.

struct TabRow: View {
    @Bindable var model: AppModel
    let tab: BrowserContext

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "safari").font(.system(size: 11)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.pageTitle).font(.system(size: 12)).lineLimit(1)
                HStack(spacing: Theme.Space.xs) {
                    Text(tab.host).font(.system(size: 10)).foregroundStyle(.tertiary)
                    if !tab.note.isEmpty {
                        Text("· \(tab.note)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            if let threadId = tab.workThreadId, let thread = model.thread(id: threadId) {
                Button(thread.title) { model.route = .thread(threadId) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .lineLimit(1)
            } else {
                Chip(text: "unfiled", color: .orange)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = URL(string: tab.url) { NSWorkspace.shared.open(url) } }
    }
}

struct CodeRow: View {
    @Bindable var model: AppModel
    let code: CodeContext

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.xs) {
                    Text(code.repositoryName).font(.system(size: 12))
                    if let branch = code.branch {
                        Text(branch).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if let agent = code.agentName {
                        Chip(text: agent.label, color: .purple)
                    }
                }
                if !code.note.isEmpty {
                    Text(code.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let threadId = code.workThreadId, let thread = model.thread(id: threadId) {
                Button(thread.title) { model.route = .thread(threadId) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
    }
}
