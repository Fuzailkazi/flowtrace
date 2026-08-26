import SwiftUI
import FlowTraceCore

// The linked-item, notes and activity sections of the thread detail screen.
// Split out so the screen's structure stays readable in one glance.
extension ThreadDetailView {
    // MARK: - Linked items

    @ViewBuilder
    var linkedRepositories: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Repositories and sessions", count: detail.code.count)
            if detail.code.isEmpty {
                Card {
                    Text("Nothing attached. Use Attach, or run `flowtrace attach` in a repository.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(detail.code) { context in
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
                                if let change = detail.repoChanges[context.repositoryPath], !change.isEmpty {
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
                                Button("Remove") { detail.removeCode(id: context.id) }
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
    var linkedTabs: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Browser tabs", count: detail.tabs.count)
            if detail.tabs.isEmpty {
                Card {
                    Text("No tabs attached yet.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(detail.tabs) { tab in
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
                                Button("Remove") { detail.removeTab(id: tab.id) }
                                    .buttonStyle(.link).font(.system(size: 10))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notes and timeline

    var notesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Notes and decisions", count: detail.notes.count)
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
                        Button("Add note") {
                            detail.addNote(draftNote, isDecision: noteIsDecision)
                            draftNote = ""
                            noteIsDecision = false
                        }
                            .controlSize(.small)
                            .disabled(draftNote.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            ForEach(detail.notes) { note in
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if note.isDecision { Chip(text: "decision", color: .blue) }
                            Spacer()
                            Text(note.createdAt.relativeShort)
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Button("Delete") { detail.deleteNote(id: note.id) }
                                .buttonStyle(.link).font(.system(size: 10))
                        }
                        Text(note.content).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    var timelineSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Activity", count: detail.timeline.count)
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(detail.timeline) { event in
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

}
