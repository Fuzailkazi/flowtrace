import SwiftUI
import FlowTraceCore

/// Settings is where the privacy promises are made checkable: what is read,
/// where it is stored, how much of it there is, and how to get it out or delete it.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var counts: [String: Int] = [:]
    @State private var confirmingDeleteAll = false
    @State private var ignored: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                sources
                extensionSection
                storage
                data
                about
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle("Settings")
        .task { reload() }
        .confirmationDialog(
            "Delete everything FlowTrace has stored?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all data", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every thread, captured tab, repository, note and activity entry is removed. "
                 + "This cannot be undone, and your own files are not touched.")
        }
    }

    // MARK: - Sources

    private var sources: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Sources", subtitle: "read-only, opt-in, local")

            source("Claude Code", isOn: $model.consent.claudeCode,
                   adapter: ClaudeCodeAdapter())
            source("Codex CLI", isOn: $model.consent.codex, adapter: CodexAdapter())

            Card {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Cursor, OpenCode and Gemini CLI")
                        .font(.system(size: 12, weight: .medium))
                    Text("Their local session stores are either incomplete or opaque, so "
                         + "FlowTrace doesn't guess at them. Attach those sessions by hand "
                         + "with Capture → Agent session.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !ignored.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    FieldLabel(text: "Never suggest these repositories")
                    Card {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            ForEach(ignored, id: \.self) { path in
                                HStack {
                                    Text(abbreviate(path))
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    Button("Stop ignoring") { unignore(path) }
                                        .buttonStyle(.link).font(.system(size: 10))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func source(_ title: String, isOn: Binding<Bool>, adapter: any AgentAdapter) -> some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .disabled(!adapter.isAvailable)
                    .onChange(of: isOn.wrappedValue) { _, _ in
                        model.consent.save()
                        model.refresh()
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        if !adapter.isAvailable { Chip(text: "not installed", color: .secondary) }
                    }
                    ForEach(adapter.searchPaths, id: \.self) { path in
                        Text(abbreviate(path))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
        }
        .opacity(adapter.isAvailable ? 1 : 0.55)
    }

    // MARK: - Browser extension

    private var extensionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Browser extension", subtitle: "optional, localhost only")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle(isOn: Binding(
                        get: { model.localServerEnabled },
                        set: { model.localServerEnabled = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Accept captures from the extension and CLI")
                                .font(.system(size: 12, weight: .medium))
                            Text("Listens on 127.0.0.1 only. Every request needs the token below.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }

                    if let error = model.serverError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.red)
                    }

                    if model.localServerEnabled {
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                FieldLabel(text: "Endpoint")
                                Text(model.serverPort.map { "http://127.0.0.1:\($0)" } ?? "starting…")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Spacer()
                            VStack(alignment: .leading, spacing: 1) {
                                FieldLabel(text: "Token")
                                Text(String(model.localAPIToken().prefix(10)) + "…")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Button("Copy token") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.localAPIToken(), forType: .string)
                                model.toast = Toast(message: "Token copied")
                            }
                            Button("Regenerate") { model.regenerateLocalAPIToken() }
                        }
                        .controlSize(.small)
                        Text("Paste the token into the FlowTrace extension's options page. "
                             + "Regenerating it disconnects any extension still using the old one.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Storage

    private var storage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Storage")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack {
                        Text(FlowTraceDatabase.defaultURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([FlowTraceDatabase.defaultURL])
                        }
                        .controlSize(.small)
                    }
                    Divider()
                    HStack(spacing: Theme.Space.l) {
                        countLabel("Threads", counts["threads"])
                        countLabel("Tabs", counts["tabs"])
                        countLabel("Repositories", counts["repositories"])
                        countLabel("Notes", counts["notes"])
                        countLabel("Activity", counts["events"])
                    }
                }
            }
        }
    }

    private func countLabel(_ title: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value ?? 0)").font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Data controls

    private var data: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Your data")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        Button("Export as JSON") { export(markdown: false) }
                        Button("Export as Markdown") { export(markdown: true) }
                        Spacer()
                    }
                    .controlSize(.small)
                    Text("An export contains your threads, captures and notes — not the scan cache.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)

                    Divider()

                    HStack(spacing: Theme.Space.s) {
                        Button("Rescan from scratch") { clearCache() }
                        Spacer()
                        Button("Delete all data…", role: .destructive) { confirmingDeleteAll = true }
                    }
                    .controlSize(.small)
                    Text("Rescanning from scratch forgets which session files were already read. "
                         + "It changes nothing in your repositories.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Privacy")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    promise("Everything stays on this machine. FlowTrace makes no network requests.")
                    promise("No account, no sync, no telemetry.")
                    promise("Browser capture stores page titles and URLs only — never page "
                            + "contents, cookies, form values or credentials.")
                    promise("Agent transcripts are read for working directory, branch, timestamps "
                            + "and your own prompts. Assistant replies and tool output are ignored.")
                    promise("Nothing is captured automatically. Every thread and every capture "
                            + "is something you confirmed.")
                }
            }
        }
    }

    private func promise(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.green)
                .padding(.top, 3)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func reload() {
        counts = (try? model.store.counts()) ?? [:]
        ignored = ((try? model.store.ignoredPaths()) ?? []).sorted()
    }

    private func export(markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "flowtrace-export.md" : "flowtrace-export.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = markdown
                ? Data(try model.store.exportMarkdown().utf8)
                : try model.store.exportJSON()
            try data.write(to: url)
            model.toast = Toast(message: "Exported to \(url.lastPathComponent)")
        } catch {
            model.toast = Toast(message: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func clearCache() {
        do {
            try model.store.clearScanCache()
            model.toast = Toast(message: "Next scan will re-read every session")
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    private func deleteAll() {
        do {
            try model.store.deleteAllData()
            model.refresh()
            reload()
            model.route = .dashboard
            model.toast = Toast(message: "All FlowTrace data deleted")
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    private func unignore(_ path: String) {
        try? model.store.stopIgnoring(path: path)
        reload()
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
