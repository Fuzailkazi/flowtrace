import SwiftUI
import FlowTraceCore

struct SearchResultsView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                if model.searchResults.isEmpty {
                    EmptyState(
                        icon: "magnifyingglass",
                        title: "No matches for \"\(model.searchText)\"",
                        message: "Search covers thread titles, intents, next steps, blockers, "
                            + "notes, page titles, URLs, repository names and agent names."
                    )
                } else {
                    SectionHeader(title: "Results", count: model.searchResults.count)
                    ForEach(model.searchResults) { hit in
                        SearchHitRow(model: model, hit: hit)
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
        .navigationTitle("Search")
    }
}

struct SearchHitRow: View {
    @Bindable var model: AppModel
    let hit: SearchHit

    var body: some View {
        Card(padding: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !hit.snippet.isEmpty {
                        Text(hit.snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let thread = model.thread(id: hit.threadId), hit.kind != .thread {
                    Text(thread.title)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.searchText = ""
            model.route = .thread(hit.threadId)
        }
    }

    private var icon: String {
        switch hit.kind {
        case .thread: "point.3.filled.connected.trianglepath.dotted"
        case .tab: "safari"
        case .code: "folder"
        case .note: "note.text"
        }
    }
}
