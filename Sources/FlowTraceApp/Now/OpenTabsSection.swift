import SwiftUI
import FlowTraceCore

/// The pages you have open, and why.
///
/// Browsers sit beside the projects in Now rather than in their own screen,
/// because "what am I in the middle of" spans both: a repository with an idle
/// agent and eleven tabs about the same problem are one situation.
///
/// Laid out as the design's "you were here recently" grid, minus the
/// screenshots: FlowTrace reads tab titles and addresses, not pixels, so each
/// card shows the title, the host, and what you said the page was for.
///
/// A note written here is keyed on the page's address, not on the tab — so it
/// survives the tab closing, which is the entire point of asking.
struct OpenTabsSection: View {
    @Bindable var model: AppModel
    let browsers: [LiveBrowser]
    var notes: [String: String]
    var onNote: (CapturedTab, String) -> Void

    @State private var expanded: Set<String> = []
    @State private var editing: String?
    @State private var hovering: String?
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var readable: [LiveBrowser] { browsers.filter { !$0.needsPermission } }
    private var denied: [LiveBrowser] { browsers.filter(\.needsPermission) }
    private var tabCount: Int { readable.reduce(0) { $0 + $1.tabs.count } }

    /// A card for what you are looking at in each browser, and for anything
    /// you have written about. Thirty-seven cards of tabs is a browser, not a
    /// summary; the rest sit behind "N more".
    private var cards: [(browser: LiveBrowser, tab: CapturedTab)] {
        readable.flatMap { browser in
            browser.tabs
                .filter { $0.isActive || notes[$0.url] != nil }
                .map { (browser: browser, tab: $0) }
        }
    }

    private func shownCount(in browser: LiveBrowser) -> Int {
        cards.filter { $0.browser.id == browser.id }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Journal.Space.l) {
            NowSectionHeader(
                symbol: "globe", title: "Open in your browser",
                trailing: "\(nowCount(tabCount, "tab")) · refreshes every 30s"
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: Journal.Space.xl)],
                alignment: .leading, spacing: Journal.Space.xl
            ) {
                ForEach(cards, id: \.tab.id) { card in
                    tabCard(card.tab, browser: card.browser)
                }
                ForEach(denied) { browser in
                    deniedCard(browser)
                }
            }

            ForEach(readable.filter { $0.tabs.count > shownCount(in: $0) }) { browser in
                moreTabs(browser)
            }
        }
    }

    // MARK: - Cards

    private func tabCard(_ tab: CapturedTab, browser: LiveBrowser) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack(spacing: Journal.Space.s) {
                NowChip(text: browser.name, symbol: "globe")
                Spacer(minLength: Journal.Space.s)
                if tab.isActive {
                    Text("active")
                        .font(.caption())
                        .foregroundStyle(Journal.pen)
                } else {
                    Text(nowCount(browser.tabs.count, "tab"))
                        .font(.caption())
                        .foregroundStyle(Journal.inkSoft)
                }
            }

            Text(tab.pageTitle)
                .font(.observed(14, weight: .semibold))
                .foregroundStyle(Journal.ink)
                .lineLimit(2, reservesSpace: true)

            reason(for: tab, compact: false)

            Spacer(minLength: 0)

            HStack(spacing: Journal.Space.s) {
                hostPill(tab.host)
                Spacer(minLength: Journal.Space.s)
                openButton(tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nowCard(padding: Journal.Space.l)
        .onHover { hovering = $0 ? tab.url : (hovering == tab.url ? nil : hovering) }
    }

    /// A browser that is open but hasn't let FlowTrace ask what is in it.
    private func deniedCard(_ browser: LiveBrowser) -> some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            HStack(spacing: Journal.Space.s) {
                NowChip(text: browser.name, symbol: "globe")
                Spacer(minLength: Journal.Space.s)
                NowChip(text: "can't read tabs", tint: Journal.amber, fill: Journal.amberSoft)
            }

            Text("FlowTrace hasn't been allowed to ask \(browser.name) which pages are open.")
                .font(.observed(12.5))
                .foregroundStyle(Journal.inkMid)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Allow…") { AutomationPermission.openSettings() }
                .buttonStyle(.plain)
                .font(.observed(12, weight: .medium))
                .foregroundStyle(Journal.pen)
                .help("Open System Settings › Privacy › Automation")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nowCard(padding: Journal.Space.l)
    }

    private func hostPill(_ host: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .font(.system(size: 9, weight: .semibold))
            Text(host)
                .font(.mono(10.5))
                .lineLimit(1)
        }
        .foregroundStyle(Journal.inkSoft)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Journal.wash, in: Capsule())
    }

    private func openButton(_ tab: CapturedTab) -> some View {
        Button {
            if let url = URL(string: tab.url) { NSWorkspace.shared.open(url) }
        } label: {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Journal.inkSoft)
        }
        .buttonStyle(.plain)
        .help("Open \(tab.url)")
    }

    // MARK: - The rest of a browser

    /// Everything else in one browser, behind a count. Expanded, it is a list
    /// rather than more cards: at that point you are scanning, not looking.
    private func moreTabs(_ browser: LiveBrowser) -> some View {
        let isExpanded = expanded.contains(browser.id)
        let hidden = browser.tabs.count - shownCount(in: browser)

        return VStack(alignment: .leading, spacing: Journal.Space.s) {
            HStack(spacing: Journal.Space.s) {
                Text(browser.name)
                    .font(.observed(12.5, weight: .medium))
                    .foregroundStyle(Journal.inkMid)
                Text(nowCount(browser.tabs.count, "tab"))
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                Spacer()
                Button(isExpanded ? "Show less" : "\(hidden) more") {
                    toggle(browser.id)
                }
                .buttonStyle(.plain)
                .font(.observed(11.5, weight: .medium))
                .foregroundStyle(Journal.pen)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabRow(tab)
                            .overlay(alignment: .bottom) {
                                if index < browser.tabs.count - 1 {
                                    Divider().overlay(Journal.rule)
                                }
                            }
                    }
                }
                .nowCard(padding: Journal.Space.s)
            }
        }
    }

    private func tabRow(_ tab: CapturedTab) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Journal.Space.s) {
                Circle()
                    .fill(tab.isActive ? Journal.pen : Journal.ruleFirm)
                    .frame(width: 5, height: 5)

                Text(tab.pageTitle)
                    .font(.observed(12.5))
                    .foregroundStyle(Journal.ink)
                    .lineLimit(1)

                Text(tab.host)
                    .font(.mono(10.5))
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)

                Spacer(minLength: Journal.Space.s)

                openButton(tab)
            }

            reason(for: tab, compact: true)
                .padding(.leading, 13)
        }
        .padding(.horizontal, Journal.Space.s)
        .padding(.vertical, Journal.Space.s)
        .onHover { hovering = $0 ? tab.url : (hovering == tab.url ? nil : hovering) }
    }

    // MARK: - Why the page is open

    @ViewBuilder
    private func reason(for tab: CapturedTab, compact: Bool) -> some View {
        if editing == tab.url {
            HStack(spacing: Journal.Space.s) {
                TextField("what is this for?", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.yourWords(compact ? 13.5 : 14))
                    .foregroundStyle(Journal.ink)
                    .focused($focused)
                    .onSubmit { commit(tab) }
                Button("Save") { commit(tab) }
                    .buttonStyle(.plain)
                    .font(.observed(10.5, weight: .medium))
                    .foregroundStyle(Journal.pen)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
            .overlay(
                RoundedRectangle(cornerRadius: Journal.Radius.chip)
                    .strokeBorder(Journal.pen, lineWidth: 1)
            )
            .onExitCommand { editing = nil }

        } else if let note = notes[tab.url] {
            Text("“\(note)”")
                .font(.yourWords(compact ? 13.5 : 14))
                .foregroundStyle(Journal.ink)
                .lineLimit(compact ? 1 : 3)
                .onTapGesture { begin(tab, existing: note) }

        } else if tab.isActive || hovering == tab.url {
            Button { begin(tab, existing: "") } label: {
                Text("say what this is for")
                    .font(.yourWords(13.5))
                    .foregroundStyle(Journal.pen)
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func begin(_ tab: CapturedTab, existing: String) {
        editing = tab.url
        draft = existing
        focused = true
    }

    private func commit(_ tab: CapturedTab) {
        onNote(tab, draft)
        editing = nil
    }
}
