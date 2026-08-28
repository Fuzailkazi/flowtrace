import SwiftUI
import FlowTraceCore

/// Settings is where the privacy promises are made checkable: what is read,
/// where it is stored, how much of it there is, and how to get it out or delete it.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var counts: [String: Int] = [:]
    @State private var confirmingDeleteAll = false
    @State private var ignored: [String] = []
    @State private var accessibilityGranted = AccessibilityPermission.isGranted
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    /// The permission is granted in System Settings, outside this app, so poll
    /// while the pane is open rather than making the user relaunch.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                alwaysOnSection
                recordingSection
                shortcutSection
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
        .onReceive(permissionTick) { _ in
            let granted = AccessibilityPermission.isGranted
            guard granted != accessibilityGranted else { return }
            accessibilityGranted = granted
            // Re-arm the trigger the moment permission appears.
            model.reregisterTrigger()
        }
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
                                    Text(path.abbreviatingHome)
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
                        Text(path.abbreviatingHome)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
        }
        .opacity(adapter.isAvailable ? 1 : 0.55)
    }

    // MARK: - Always on

    /// A capture shortcut that only works when you remembered to launch the app
    /// is not a capture shortcut. This section exists because the debug log
    /// showed the trigger registering on every launch and never once firing.
    private var alwaysOnSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Always there", subtitle: "so the shortcut works")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle(isOn: Binding(
                        get: { launchAtLogin },
                        set: { wanted in
                            _ = LaunchAtLogin.set(wanted)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Start FlowTrace when I log in")
                                .font(.system(size: 12, weight: .medium))
                            Text(LaunchAtLogin.statusDescription)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    Text("Closing the window puts FlowTrace away rather than quitting it — "
                         + "the shortcut only works while it's running. Quit properly from "
                         + "the menubar or with ⌘Q.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Recording

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Your day", subtitle: "off until you turn it on")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Toggle(isOn: Binding(
                        get: { model.isRecording },
                        set: { model.isRecording = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Write down what I'm doing")
                                .font(.system(size: 12, weight: .medium))
                            Text("Which app is in front, and what it's showing. "
                                 + "Nothing is recorded while the screen is locked "
                                 + "or you've stepped away, and FlowTrace never "
                                 + "records itself.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if model.isRecording {
                        Divider()
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: accessibilityGranted
                                  ? "checkmark.circle.fill" : "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(accessibilityGranted ? .green : .orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(accessibilityGranted
                                     ? "Window titles are being read"
                                     : "Without Accessibility, entries show the app only")
                                    .font(.system(size: 12, weight: .medium))
                                Text(accessibilityGranted
                                     ? "Read once when you switch apps — never watched continuously."
                                     : "\"Chrome\" tells you little; \"Chrome — pencil.com\" tells you what you were doing.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if !accessibilityGranted {
                                Button("Grant…") {
                                    AccessibilityPermission.request()
                                    AccessibilityPermission.openSettings()
                                }
                                .controlSize(.small)
                            }
                        }

                        HStack {
                            Text("Delete everything recorded today")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget today", role: .destructive) {
                                try? model.store.deleteActivity(on: Date())
                                model.toast = Toast(message: "Today's record deleted")
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, Theme.Space.xs)
                    }
                }
            }
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Shortcut", subtitle: "opens the \"why am I here?\" panel")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Picker("", selection: triggerKind) {
                        Text("Key combination").tag(TriggerKind.chord)
                        Text("Tap a modifier").tag(TriggerKind.tap)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch model.captureTrigger {
                    case .chord:
                        chordControls
                    case .modifierTap(let key, let taps):
                        tapControls(key: key, taps: taps)
                    }

                    if let failure = model.shortcutFailure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private enum TriggerKind { case chord, tap }

    private var triggerKind: Binding<TriggerKind> {
        Binding(
            get: {
                if case .modifierTap = model.captureTrigger { return .tap }
                return .chord
            },
            set: { kind in
                switch kind {
                case .chord:
                    model.captureTrigger = .chord(model.lastChord)
                case .tap:
                    model.captureTrigger = .modifierTap(key: .leftOption, taps: 1)
                }
            }
        )
    }

    @ViewBuilder
    private var chordControls: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("Needs no permission and can't fire by accident.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            ShortcutRecorder(shortcut: Binding(
                get: { model.lastChord },
                set: {
                    model.lastChord = $0
                    model.captureTrigger = .chord($0)
                }
            ))
        }
    }

    @ViewBuilder
    private func tapControls(key: ModifierKey, taps: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Picker("", selection: Binding(
                    get: { key },
                    set: { model.captureTrigger = .modifierTap(key: $0, taps: taps) }
                )) {
                    ForEach(ModifierKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)

                Picker("", selection: Binding(
                    get: { taps },
                    set: { model.captureTrigger = .modifierTap(key: key, taps: $0) }
                )) {
                    Text("Single tap").tag(1)
                    Text("Double tap").tag(2)
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
            }
            .controlSize(.small)

            if taps == 1 {
                Text("A single tap of a key you also use as a modifier will "
                     + "sometimes fire when you didn't mean it. Double tap is far "
                     + "steadier if that starts to annoy you.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            accessibilityRow
        }
    }

    /// Tapping a modifier means watching keys pressed in other apps, which is
    /// precisely what Accessibility gates. Say so, and make it one click.
    @ViewBuilder
    private var accessibilityRow: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(accessibilityGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(accessibilityGranted
                     ? "Accessibility granted"
                     : "Needs the Accessibility permission")
                    .font(.system(size: 12, weight: .medium))
                Text(accessibilityGranted
                     ? "Because this build isn't signed with a Developer ID, macOS "
                       + "may ask again after an update."
                     : "macOS only lets an app watch keys pressed elsewhere with "
                       + "your explicit permission.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !accessibilityGranted {
                Button("Grant…") {
                    AccessibilityPermission.request()
                    AccessibilityPermission.openSettings()
                }
                .controlSize(.small)
            }
        }
        .padding(.top, Theme.Space.xs)
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

}
