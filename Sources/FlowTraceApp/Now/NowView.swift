import SwiftUI
import FlowTraceCore

/// The state of your machine, right now.
///
/// The front door, because "eleven agents running, eight idle for four days" is
/// a stronger thing to open on than a record of what you did at 09:12. History
/// is one click away; this is what you can act on.
///
/// Laid out as the approved design: one spotlight card for the place that is
/// moving, compact cards for everything else still running, then the pages you
/// have open and the notes you've written against them. Everything on the page
/// is read from this Mac in the last few seconds; nothing is estimated.
struct NowView: View {
    @Bindable var model: AppModel

    @State private var state = LiveState()
    @State private var projects: [LiveProject] = []
    @State private var notes: [String: ProjectNote] = [:]
    @State private var editing: String?
    @State private var draft = ""
    @State private var loading = true
    @State private var hovering: String?
    @State private var ignored: Set<String> = []
    @State private var browsers: [LiveBrowser] = []
    @State private var tabNotes: [String: String] = [:]
    /// A store read that failed. Kept on screen until a later read succeeds:
    /// "nothing is running" and "I couldn't look" must not render alike.
    @State private var failure: String?
    @FocusState private var focused: Bool

    private let tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    /// Reading every tab costs about half a second across three browsers — fine
    /// occasionally, far too much at the rate the agent list refreshes.
    private let browserTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// The design's `max-w-6xl`, centred in whatever the window gives us.
    private static let contentWidth: CGFloat = 1152
    /// The spotlight card's inner padding (`p-7`).
    private static let spotlightPadding: CGFloat = 28

    private var forgotten: Int { projects.filter(\.isForgotten).count }
    private var agentCount: Int { projects.reduce(0) { $0 + $1.agents.count } }
    private var serverCount: Int { projects.reduce(0) { $0 + $1.servers.count } }
    private var anyoneWorking: Bool { state.agents.contains { $0.state == .working } }

    /// `projects` is already sorted live-first then most-recent-first, so the
    /// first entry is the place that is moving — or, if nothing is, the place
    /// that moved last.
    private var spotlight: LiveProject? { projects.first }
    private var others: [LiveProject] { Array(projects.dropFirst()) }

    /// True when more than one kind of agent is running, which is the only time
    /// naming it on each row tells the reader anything.
    private var agentsAreMixed: Bool {
        Set(state.agents.map(\.agent)).count > 1
    }

    /// Every open page you have written a reason against, once each.
    private var notedTabs: [CapturedTab] {
        var seen = Set<String>()
        return browsers.flatMap(\.tabs).filter { tab in
            tabNotes[tab.url] != nil && seen.insert(tab.url).inserted
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Journal.Space.section) {
                header

                if let failure {
                    LoadFailureNotice(message: failure) {
                        Task { await refresh(); await refreshBrowsers() }
                    }
                }

                if loading && state.agents.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, Journal.Space.xl)
                } else {
                    if let spotlight {
                        spotlightCard(spotlight)
                    } else if failure == nil {
                        empty
                    }

                    if !others.isEmpty {
                        alsoRunning
                    }

                    // Tabs are evidence about the work even when no agents or
                    // servers are running. Hiding them behind `projects.isEmpty`
                    // left an empty screen that hid the one thing we did know.
                    if !browsers.isEmpty {
                        OpenTabsSection(
                            model: model, browsers: browsers, notes: tabNotes,
                            onNote: { tab, text in noteTab(tab, text) }
                        )
                    }

                    if !notedTabs.isEmpty {
                        ConnectedThoughtsSection(
                            tabs: notedTabs, notes: tabNotes,
                            onNote: { tab, text in noteTab(tab, text) }
                        )
                    }
                }

                footer
            }
            .padding(.horizontal, 40)
            .padding(.vertical, Journal.Space.xxl)
            .frame(maxWidth: Self.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Journal.paper)
        .task {
            await refresh()
            await refreshBrowsers()
        }
        .onChange(of: model.consent) { _, _ in
            Task { await refresh(); await refreshBrowsers() }
        }
        .onChange(of: model.activityRevision) { _, _ in
            Task { await refreshBrowsers() }
        }
        .onReceive(tick) { _ in Task { await refresh() } }
        .onReceive(browserTick) { _ in Task { await refreshBrowsers() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: Journal.Space.xl) {
            VStack(alignment: .leading, spacing: Journal.Space.s) {
                HStack(spacing: Journal.Space.s) {
                    NowPulsingDot(color: Journal.pen, pulsing: anyoneWorking)
                    Text("RIGHT NOW")
                        .font(.caption())
                        .tracking(1.0)
                        .foregroundStyle(Journal.inkSoft)
                }
                Text("What are you working on?")
                    .font(.journalTitle(28))
                    .tracking(-0.4)
                    .foregroundStyle(Journal.ink)
            }

            Spacer(minLength: Journal.Space.l)

            if !loading {
                statusPill
            }
        }
    }

    /// What the design labelled "Focus since 2:15 PM · 18 moments captured",
    /// said truthfully: how many things are running, and how many of them you
    /// have forgotten about. The forgotten count is the surprising half, so it
    /// gets the colour.
    private var statusPill: some View {
        HStack(spacing: Journal.Space.m) {
            HStack(spacing: -6) {
                pillIcon("terminal", tint: Journal.pen)
                pillIcon("chevron.left.forwardslash.chevron.right", tint: Journal.inkMid)
                pillIcon("globe", tint: Journal.inkSoft)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(nowCount(agentCount, "agent")) · \(nowCount(serverCount, "server"))")
                    .font(.observed(11, weight: .medium))
                    .foregroundStyle(Journal.ink)
                if forgotten > 0 {
                    Text("\(forgotten) left running and forgotten")
                        .font(.caption())
                        .foregroundStyle(Journal.amber)
                } else {
                    Text("nothing forgotten")
                        .font(.caption())
                        .foregroundStyle(Journal.inkSoft)
                }
            }
        }
        .padding(.horizontal, Journal.Space.l)
        .padding(.vertical, Journal.Space.s)
        .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
    }

    private func pillIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(Journal.card)
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            )
    }

    // MARK: - Spotlight

    /// The place that is moving, given the room the design gives it.
    private func spotlightCard(_ project: LiveProject) -> some View {
        let canonical = FilePathCanon.canonical(project.path)
        let isLive = project.agents.contains { $0.state.isActive }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Journal.Space.xl) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: Journal.Space.s) {
                        // "Active" only when something here is awake. An idle
                        // agent's project is the last one you touched, not the
                        // one you are working in.
                        NowChip(text: isLive ? "Active project" : "Last active project")
                        if let who = whoIsHere(project) {
                            Text(who)
                                .font(.caption())
                                .foregroundStyle(Journal.inkSoft)
                                .lineLimit(1)
                        }
                    }

                    Text(project.name)
                        .font(.journalTitle(22))
                        .tracking(-0.4)
                        .foregroundStyle(Journal.ink)

                    subline(project)
                }

                Spacer(minLength: Journal.Space.l)

                HStack(spacing: Journal.Space.m) {
                    Button {
                        model.route = .place(project.path)
                    } label: {
                        Label("What was I doing here?", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(NowPrimaryButtonStyle())
                    .help("Open what FlowTrace remembers about \(project.name)")

                    Button {
                        openInFinder(project)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(NowIconButtonStyle())
                    .help("Open \(project.path) in Finder")

                    Button {
                        begin(path: project.path, existing: notes[canonical]?.building ?? "")
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(NowIconButtonStyle())
                    .help("Say what you're building here")
                }
            }
            .padding(Self.spotlightPadding)

            // The design's "current workspace thread" band: the last thing you
            // asked an agent here, and what you said you were building.
            threadStrip(project)
                .padding(.horizontal, Self.spotlightPadding)
                .padding(.vertical, Journal.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Journal.paperDeep.opacity(0.7))
        }
        .background(Journal.card)
        .clipShape(RoundedRectangle(cornerRadius: Journal.Radius.card))
        .compositingGroup()
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
        .contentShape(Rectangle())
        .contextMenu { projectMenu(project) }
    }

    /// "Claude Code · pid 48209" — who is actually here, by process.
    private func whoIsHere(_ project: LiveProject) -> String? {
        if let agent = project.agents.first {
            var text = "\(agent.agent.label) · pid \(agent.pid)"
            if project.agents.count > 1 {
                text += " · \(nowCount(project.agents.count, "agent"))"
            }
            return text
        }
        if let server = project.servers.first {
            return "\(server.processName) · pid \(server.pid)"
        }
        return nil
    }

    /// agent · status · listening :5173 — the ports stay clickable.
    private func subline(_ project: LiveProject) -> some View {
        var parts: [String] = []
        if let agent = project.agents.first { parts.append(agent.agent.label) }
        if !project.statusLabel.isEmpty { parts.append(project.statusLabel) }

        return HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { dot }
                Text(part).foregroundStyle(Journal.inkMid)
            }
            if !project.servers.isEmpty {
                if !parts.isEmpty { dot }
                Text("listening").foregroundStyle(Journal.inkMid)
                portChips(project)
            }
        }
        .font(.observed(13))
    }

    private var dot: some View {
        Text("·").foregroundStyle(Journal.inkSoft)
    }

    @ViewBuilder
    private func threadStrip(_ project: LiveProject) -> some View {
        let canonical = FilePathCanon.canonical(project.path)
        let building = notes[canonical]?.building ?? ""

        VStack(alignment: .leading, spacing: Journal.Space.s) {
            HStack(spacing: Journal.Space.l) {
                Text("Current workspace thread")
                    .font(.observed(11, weight: .medium))
                    .foregroundStyle(Journal.inkSoft)
                    .layoutPriority(1)

                if let prompt = project.lastPrompt {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Journal.pen)
                        Text(oneLine(prompt))
                            .font(.mono(12))
                            .foregroundStyle(Journal.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else if building.isEmpty && editing != canonical {
                    invitation(project)
                }
            }

            if editing == canonical {
                noteEditor(project)
            } else if !building.isEmpty {
                Text("“\(building)”")
                    .font(.yourWords(15))
                .foregroundStyle(Journal.ink)
                .onTapGesture { begin(path: project.path, existing: building) }
            }

            if let prompt = project.lastPrompt, !prompt.isEmpty {
                contextLine(label: "last instruction", text: oneLine(prompt))
            }
        }
    }

    private func contextLine(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption(9))
                .tracking(0.8)
                .foregroundStyle(Journal.inkSoft)
            Text(text)
                .font(.observed(12.5))
                .foregroundStyle(Journal.inkMid)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Also running

    private var alsoRunning: some View {
        VStack(alignment: .leading, spacing: Journal.Space.l) {
            NowSectionHeader(
                symbol: "square.stack", title: "Also running",
                trailing: nowCount(others.count, "place")
            )
            VStack(spacing: Journal.Space.m) {
                ForEach(others) { project in
                    projectRow(project)
                }
            }
        }
    }

    /// Everything happening in one project: its agents, its servers, and what
    /// you said you were building. Grouped because work happens in places — the
    /// previous split across two lists hid that a project could have an agent
    /// idle for days *and* a server still holding a port.
    private func projectRow(_ project: LiveProject) -> some View {
        let canonical = FilePathCanon.canonical(project.path)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Journal.Space.s) {
                Circle()
                    .fill(colour(for: project))
                    .frame(width: 7, height: 7)

                Text(project.name)
                    .font(.observed(14, weight: .semibold))
                    .foregroundStyle(Journal.ink)

                // The agent's name only when it isn't the same one on every row.
                if agentsAreMixed, let agent = project.agents.first?.agent {
                    Text(agent.label)
                        .font(.observed(10.5))
                        .foregroundStyle(Journal.inkSoft)
                }

                Spacer(minLength: Journal.Space.s)

                if hovering == canonical {
                    Menu {
                        if notes[canonical] != nil {
                            Button("Clear what I wrote") { clearNote(project) }
                        }
                        Button("Hide this project") { hide(project) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Journal.inkSoft)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Hide this project, or clear its note")
                }

                // Staleness is stated in words; it doesn't also need a colour.
                // Amber belongs to one thing only, and spending it here left
                // nothing to distinguish what actually wants attention.
                Text(project.statusLabel)
                    .font(.observed(11))
                    .foregroundStyle(Journal.inkSoft)
            }

            if let prompt = project.lastPrompt {
                Text(prompt)
                    .font(.observed(12.5))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(2)
            }

            if !project.servers.isEmpty {
                HStack(spacing: Journal.Space.s) {
                    Text("listening")
                        .font(.observed(10.5))
                        .foregroundStyle(Journal.inkSoft)
                    portChips(project)
                    Spacer()
                }
            }

            projectNote(for: project)
        }
        .nowCard(padding: Journal.Space.l)
        .onHover { hovering = $0 ? canonical : (hovering == canonical ? nil : hovering) }
        .contextMenu { projectMenu(project) }
    }

    private func portChips(_ project: LiveProject) -> some View {
        HStack(spacing: Journal.Space.xs) {
            ForEach(project.servers) { server in
                Button {
                    if let url = URL(string: server.address) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(":\(String(server.port))")
                        .font(.mono(11))
                        .foregroundStyle(Journal.pen)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Open \(server.address)")
            }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: LiveProject) -> some View {
        Button("What was I doing here?") { model.route = .place(project.path) }
        Button("Open in Finder") { openInFinder(project) }
        Button("Copy path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        if notes[FilePathCanon.canonical(project.path)] != nil {
            Button("Clear what I wrote") { clearNote(project) }
        }
        Button("Hide this project", role: .destructive) { hide(project) }
    }

    // MARK: - Your note

    /// What you're building here — written once, kept forever, shown every time.
    ///
    /// Keyed on the repository rather than the session or the process, so it
    /// outlives the thing it describes.
    @ViewBuilder
    private func projectNote(for project: LiveProject) -> some View {
        let canonical = FilePathCanon.canonical(project.path)
        let building = notes[canonical]?.building ?? ""

        if editing == canonical {
            noteEditor(project)

        } else if !building.isEmpty {
            Text("“\(building)”")
                .font(.yourWords(15))
                .foregroundStyle(Journal.ink)
                .onTapGesture { begin(path: project.path, existing: building) }

        } else if hovering == canonical {
            // Only under the cursor. A filled bar on every row turns an
            // invitation into wallpaper, and made amber — which is supposed to
            // mean one thing — the loudest colour on the screen.
            invitation(project)
        }
    }

    private func invitation(_ project: LiveProject) -> some View {
        Button { begin(path: project.path, existing: "") } label: {
            Text("say what you're building here")
                .font(.yourWords(14))
                .foregroundStyle(Journal.pen)
        }
        .buttonStyle(.plain)
    }

    private func noteEditor(_ project: LiveProject) -> some View {
        HStack(spacing: Journal.Space.s) {
            TextField("what are you building here?", text: $draft)
                .textFieldStyle(.plain)
                .font(.yourWords(15))
                .foregroundStyle(Journal.ink)
                .focused($focused)
                .onSubmit { save(path: project.path, name: project.name) }
            Button("Save") { save(path: project.path, name: project.name) }
                .buttonStyle(.plain)
                .font(.observed(11, weight: .medium))
                .foregroundStyle(Journal.pen)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.field)
                .strokeBorder(Journal.pen, lineWidth: 1)
        )
        .onExitCommand { editing = nil }
    }

    // MARK: - Empty and footer

    private var empty: some View {
        VStack(alignment: .leading, spacing: Journal.Space.s) {
            Text("Nothing running.")
                .font(.journalTitle(19))
                .foregroundStyle(Journal.ink)
            Text("No coding agents and no local servers. Start one and it appears here. Press \(model.captureTrigger.displayString) anywhere to note why you're here.")
                .font(.observed(13.5))
                .foregroundStyle(Journal.inkMid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .nowCard(padding: Self.spotlightPadding)
    }

    /// The design's privacy seal, with what FlowTrace actually does.
    private var footer: some View {
        HStack(spacing: Journal.Space.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .medium))
            Text("Reads processes, transcripts and tab titles on this Mac. Nothing leaves it.")
                .lineLimit(2)
            Spacer(minLength: Journal.Space.l)
            Text("Refreshes every 8s · tabs every 30s")
                .lineLimit(1)
        }
        .font(.caption())
        .foregroundStyle(Journal.inkSoft)
        .padding(.horizontal, Journal.Space.xl)
        .padding(.vertical, Journal.Space.m)
        .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
    }

    // MARK: - Data

    private func colour(for project: LiveProject) -> Color {
        switch project.state {
        case .working: return Journal.live
        case .waiting: return Journal.pen
        // Forgotten is the one the screen exists for, so it is the one thing
        // that gets a colour of its own rather than the neutral rule.
        case .forgotten: return Journal.amber
        case .quiet, nil: return Journal.ruleFirm
        }
    }

    private func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func openInFinder(_ project: LiveProject) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }

    private func recomputeProjects() {
        projects = state.projects(notes: notes).filter { !ignored.contains($0.path) }
        // The recovery screen reads the row the user was looking at rather than
        // taking a second census, so the two can never disagree about what is
        // running.
        model.recordCensus(projects)
    }

    /// Hiding rather than deleting, because the process is still running and
    /// would simply reappear. Reuses the same ignore list the detector uses, so
    /// there is one place to undo it: Settings → Sources.
    private func hide(_ project: LiveProject) {
        do {
            try model.store.ignore(path: project.path, reason: "hidden from Now")
            ignored.insert(FilePathCanon.canonical(project.path))
            recomputeProjects()
            model.toast = Toast(message: "Hiding \(project.name) — undo in Settings")
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    private func clearNote(_ project: LiveProject) {
        do {
            try model.store.deleteProjectNote(repositoryPath: project.path)
            notes.removeValue(forKey: FilePathCanon.canonical(project.path))
            recomputeProjects()
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    private func begin(path: String, existing: String) {
        editing = FilePathCanon.canonical(path)
        draft = existing
        focused = true
    }

    private func save(path: String, name: String) {
        let canonical = FilePathCanon.canonical(path)
        var note = notes[canonical] ?? ProjectNote(repositoryPath: path, repositoryName: name)
        note.building = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let saved = try model.store.saveProjectNote(note)
            notes[canonical] = saved
            recomputeProjects()
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
        editing = nil
    }

    /// A page's reason is keyed on its address, so it outlives the tab.
    private func noteTab(_ tab: CapturedTab, _ text: String) {
        do {
            _ = try model.store.noteTab(
                url: tab.url, title: tab.pageTitle, browser: tab.browser, note: text
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { tabNotes.removeValue(forKey: tab.url) }
            else { tabNotes[tab.url] = trimmed }
        } catch {
            model.toast = Toast(message: error.localizedDescription, isError: true)
        }
    }

    private func refreshBrowsers() async {
        let mayObserve = model.mayObserve
        guard mayObserve else { browsers = []; return }
        let store = model.store
        let read = await Task.detached(priority: .utility) {
            () -> ([LiveBrowser], Result<[String: String], Error>) in
            let open = LiveStateReader().readBrowsers(allowed: mayObserve)
            do {
                var found: [String: String] = [:]
                for browser in open {
                    for tab in browser.tabs {
                        if let note = try store.noteForTab(url: tab.url) { found[tab.url] = note }
                    }
                }
                return (open, .success(found))
            } catch {
                return (open, .failure(error))
            }
        }.value

        browsers = read.0
        switch read.1 {
        case .success(let found):
            tabNotes = found
            failure = nil
        case .failure(let error):
            // Without this the reasons you wrote against open pages vanish from
            // the grid and from Connected thoughts, looking like you never
            // wrote them.
            failure = error.localizedDescription
        }
    }

    /// Reading processes shells out, so it never happens on the main actor.
    ///
    /// The live read cannot fail — it returns what it could see. The two store
    /// reads can, and when they do the screen says so instead of quietly
    /// dropping your project notes and un-hiding everything you hid.
    private func refresh() async {
        // Hoisted onto the main actor before the hop, and checked here rather
        // than inside the reader: the permission is a value the caller holds,
        // not a global the reader reaches for.
        guard model.mayObserve else {
            state = LiveState()
            projects = []
            loading = false
            return
        }
        let sources = model.readableSources
        let store = model.store
        let read = await Task.detached(priority: .userInitiated) {
            () -> (LiveState, Result<([ProjectNote], Set<String>), Error>) in
            let live = LiveStateReader().read(transcripts: sources)
            do {
                return (live, .success((try store.allProjectNotes(), try store.ignoredPaths())))
            } catch {
                return (live, .failure(error))
            }
        }.value

        state = read.0
        switch read.1 {
        case .success(let (projectNotes, ignoredPaths)):
            notes = Dictionary(uniqueKeysWithValues: projectNotes.map { ($0.repositoryPath, $0) })
            ignored = ignoredPaths
            failure = nil
        case .failure(let error):
            // Keep whatever was already loaded rather than blanking the screen.
            failure = error.localizedDescription
        }
        recomputeProjects()
        loading = false
    }
}
