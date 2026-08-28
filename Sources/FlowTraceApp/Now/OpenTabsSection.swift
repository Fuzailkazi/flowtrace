import SwiftUI
import FlowTraceCore

/// The pages you have open, and why.
///
/// Browsers sit beside the projects in Now rather than in their own screen,
/// because "what am I in the middle of" spans both: a repository with an idle
/// agent and eleven tabs about the same problem are one situation.
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
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if !browsers.isEmpty {
            Text("Open")
                .font(.observed(10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Journal.inkSoft)
                .padding(.top, Journal.Space.l)
                .padding(.bottom, Journal.Space.s)

            ForEach(browsers) { browser in
                browserBlock(browser)
            }
        }
    }

    private func browserBlock(_ browser: LiveBrowser) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Journal.Space.s) {
                Text(browser.name)
                    .font(.observed(14, weight: .semibold))
                    .foregroundStyle(Journal.ink)

                if browser.needsPermission {
                    Text("can't read tabs")
                        .font(.observed(10.5, weight: .medium))
                        .foregroundStyle(Journal.amber)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("\(browser.tabs.count) tab\(browser.tabs.count == 1 ? "" : "s")")
                        .font(.observed(11))
                        .foregroundStyle(Journal.inkSoft)
                }

                Spacer()

                if browser.needsPermission {
                    Button("Allow…") { AutomationPermission.openSettings() }
                        .buttonStyle(.plain)
                        .font(.observed(11, weight: .medium))
                        .foregroundStyle(Journal.pen)
                } else if browser.otherTabCount > 0 {
                    Button(expanded.contains(browser.id)
                           ? "Show less" : "\(browser.otherTabCount) more") {
                        toggle(browser.id)
                    }
                    .buttonStyle(.plain)
                    .font(.observed(11))
                    .foregroundStyle(Journal.pen)
                }
            }

            // Unexpanded, only what you're looking at and anything you've written
            // about. Thirty-seven rows of tabs is a browser, not a summary.
            ForEach(visibleTabs(of: browser)) { tab in
                tabRow(tab, browser: browser)
            }
        }
        .padding(.vertical, Journal.Space.m)
        .overlay(alignment: .bottom) { Divider().overlay(Journal.rule) }
    }

    private func visibleTabs(of browser: LiveBrowser) -> [CapturedTab] {
        if expanded.contains(browser.id) { return browser.tabs }
        return browser.tabs.filter { $0.isActive || notes[$0.url] != nil }
    }

    private func tabRow(_ tab: CapturedTab, browser: LiveBrowser) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Journal.Space.s) {
                if tab.isActive {
                    Circle().fill(Journal.pen).frame(width: 5, height: 5)
                } else {
                    Circle().fill(Journal.ruleFirm).frame(width: 5, height: 5)
                }

                Text(tab.pageTitle)
                    .font(.observed(12.5))
                    .foregroundStyle(Journal.ink)
                    .lineLimit(1)

                Text(tab.host)
                    .font(.observed(10.5))
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)

                Spacer(minLength: Journal.Space.s)

                Button("Open") {
                    if let url = URL(string: tab.url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.plain)
                .font(.observed(10.5))
                .foregroundStyle(Journal.pen)
            }

            reason(for: tab, browser: browser)
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func reason(for tab: CapturedTab, browser: LiveBrowser) -> some View {
        if editing == tab.url {
            HStack(spacing: Journal.Space.s) {
                TextField("what is this for?", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.yourWords(14))
                    .foregroundStyle(Journal.ink)
                    .focused($focused)
                    .onSubmit { commit(tab) }
                Button("Save") { commit(tab) }
                    .buttonStyle(.plain)
                    .font(.observed(10.5, weight: .medium))
                    .foregroundStyle(Journal.pen)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Journal.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Journal.pen, lineWidth: 1))
            .padding(.leading, 13)
            .onExitCommand { editing = nil }

        } else if let note = notes[tab.url] {
            Text("“\(note)”")
                .font(.yourWords(14))
                .foregroundStyle(Journal.ink)
                .padding(.leading, 13)
                .onTapGesture { begin(tab, existing: note) }

        } else if tab.isActive {
            Button { begin(tab, existing: "") } label: {
                HStack(spacing: 6) {
                    Circle().fill(Journal.amber).frame(width: 5, height: 5)
                    Text("what is this for?")
                        .font(.yourWords(13.5))
                        .foregroundStyle(Journal.amber)
                    Spacer()
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Journal.amberSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.leading, 13)
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
