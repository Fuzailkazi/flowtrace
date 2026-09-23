import SwiftUI
import FlowTraceCore

/// Notes you have written against pages that are open right now.
///
/// These are the notes you typed under a tab, gathered in one place so your
/// own words are readable without hunting through the browser grid. Clicking
/// one edits it through the same path that wrote it.
struct ConnectedThoughtsSection: View {
    /// Noted tabs only, one per address.
    let tabs: [CapturedTab]
    let notes: [String: String]
    var onNote: (CapturedTab, String) -> Void

    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Journal.Space.l) {
            NowSectionHeader(
                symbol: "text.bubble", title: "Notes on open pages",
                trailing: nowCount(tabs.count, "note")
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: Journal.Space.l)],
                alignment: .leading, spacing: Journal.Space.l
            ) {
                ForEach(tabs) { tab in
                    card(tab)
                }
            }
        }
    }

    private func card(_ tab: CapturedTab) -> some View {
        HStack(alignment: .top, spacing: Journal.Space.l) {
            Image(systemName: "note.text")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Journal.pen)
                .frame(width: 36, height: 36)
                .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: Journal.Radius.field))

            VStack(alignment: .leading, spacing: Journal.Space.xs) {
                if editing == tab.url {
                    editor(tab)
                } else if let note = notes[tab.url] {
                    Text("“\(note)”")
                        .font(.yourWords(15))
                        .foregroundStyle(Journal.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { begin(tab, existing: note) }
                        .help("Change what you wrote")
                }

                Text("\(tab.pageTitle) · \(tab.host)")
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nowCard(padding: Journal.Space.l)
    }

    private func editor(_ tab: CapturedTab) -> some View {
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
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.chip)
                .strokeBorder(Journal.pen, lineWidth: 1)
        )
        .onExitCommand { editing = nil }
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
