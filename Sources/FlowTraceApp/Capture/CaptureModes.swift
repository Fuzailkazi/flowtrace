import SwiftUI
import FlowTraceCore

// The three ways context enters FlowTrace by hand: browser tabs, a
// repository, and a manual note for agents that can't be auto-discovered.
extension CaptureSheet {
    // MARK: - Tabs

    @ViewBuilder
    var tabsSection: some View {
        if availableBrowsers.isEmpty {
            EmptyState(
                icon: "safari",
                title: "No supported browser is running",
                message: "Open Chrome, Brave, Safari, Arc, Dia, Edge, Opera or Vivaldi and try again. "
                    + "FlowTrace won't launch a browser just to read its tabs."
            )
        } else {
            HStack(spacing: Theme.Space.s) {
                Picker("", selection: Binding(
                    get: { browser ?? availableBrowsers[0] },
                    set: { browser = $0; readTabs(activeOnly: false) }
                )) {
                    ForEach(availableBrowsers) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)

                Button("Front window") { readTabs(activeOnly: false) }
                Button("Current tab only") { readTabs(activeOnly: true) }
                Spacer()
                if isReading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            if let readError {
                Card {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(readError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                        if let recovery {
                            Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !tabs.isEmpty {
                HStack {
                    Text("FlowTrace stores the title and URL only — never page contents or cookies.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(selected.count == tabs.count ? "Deselect all" : "Select all") {
                        selected = selected.count == tabs.count ? [] : Set(tabs.map(\.id))
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(tabs) { tab in
                            HStack(alignment: .top, spacing: Theme.Space.s) {
                                Toggle("", isOn: Binding(
                                    get: { selected.contains(tab.id) },
                                    set: { on in
                                        if on { selected.insert(tab.id) } else { selected.remove(tab.id) }
                                    }
                                ))
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: Theme.Space.xs) {
                                        Text(tab.pageTitle).font(.system(size: 12)).lineLimit(1)
                                        if tab.isActive { Chip(text: "current", color: .blue) }
                                    }
                                    Text(tab.url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                LabeledField("Why did you open these?", text: $tabNote, axis: .vertical)
            }
        }
    }

    // MARK: - Repository

    var repositorySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Button("Choose folder…") { pickFolder() }
                if !repositoryPath.isEmpty {
                    Text(repositoryPath).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
            }
            .controlSize(.small)

            if let gitState {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Theme.Space.xs) {
                            Text(gitState.repositoryName).font(.system(size: 13, weight: .medium))
                            Chip(text: gitState.branch, color: .blue)
                            if gitState.dirtyFileCount > 0 {
                                Chip(text: "\(gitState.dirtyFileCount) uncommitted", color: .orange)
                            }
                            if gitState.commitsAhead > 0 {
                                Chip(text: "\(gitState.commitsAhead) unpushed", color: .orange)
                            }
                        }
                        if let sha = gitState.headSha {
                            Text("HEAD \(sha.prefix(7)) · \(gitState.daysSinceLastCommit)d since last commit")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
            } else if !repositoryPath.isEmpty {
                Card {
                    Label("That folder isn't inside a git repository.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
            }

            agentPicker
            LabeledField("Note", text: $contextNote, axis: .vertical)
            LabeledField("What should you do next here?", text: $contextNextStep, axis: .vertical)
        }
    }

    // MARK: - Manual agent session

    var sessionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("For agents FlowTrace can't read automatically — Cursor, OpenCode, Gemini CLI "
                 + "and anything else. Claude Code and Codex sessions are found by scanning.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Button("Choose the repository…") { pickFolder() }
                if let gitState {
                    Text("\(gitState.repositoryName) · \(gitState.branch)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .controlSize(.small)

            agentPicker
            LabeledField("What did you ask it to do?", text: $contextNote, axis: .vertical)
            LabeledField("What's left?", text: $contextNextStep, axis: .vertical)
        }
    }

    var agentPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            FieldLabel(text: "Agent")
            Picker("", selection: $agent) {
                Text("None").tag(AgentName?.none)
                ForEach(AgentName.allCases, id: \.self) { Text($0.label).tag(AgentName?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 200)
            .controlSize(.small)
        }
    }

}
