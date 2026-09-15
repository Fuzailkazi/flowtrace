import SwiftUI
import FlowTraceCore

/// The left rail from the design: brand, the three surfaces, Settings, and
/// what FlowTrace is holding. Navigation only — every item maps onto an
/// existing `Route`.
struct AppSidebar: View {
    @Bindable var model: AppModel
    @State private var holdings: Store.Holdings?
    /// A failed read of what is held. "—" reads as "nothing yet"; this says
    /// which of the two it is.
    @State private var holdingsFailure: String?

    private enum Item: Hashable {
        case now, timeline, memories, settings

        var title: String {
            switch self {
            case .now: "Now"
            case .timeline: "Timeline"
            case .memories: "Memories"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .now: "chevron.backward"
            case .timeline: "clock"
            case .memories: "photo.on.rectangle.angled"
            case .settings: "gearshape"
            }
        }

        var route: Route {
            switch self {
            case .now: .now
            case .timeline: .timeline
            case .memories: .memories
            case .settings: .settings
            }
        }
    }

    private var selected: Item? {
        switch model.route {
        case .now: .now
        case .timeline: .timeline
        case .memories, .memory: .memories
        case .settings: .settings
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup()
                .padding(.horizontal, Journal.Space.l)
                // Clears the traffic lights on a hidden-title-bar window.
                .padding(.top, 38)
                .padding(.bottom, Journal.Space.l)

            VStack(spacing: 2) {
                row(.now)
                row(.timeline)
                row(.memories)
            }
            .padding(.horizontal, Journal.Space.m)

            Spacer(minLength: Journal.Space.l)

            VStack(alignment: .leading, spacing: Journal.Space.s) {
                row(.settings)
                storage
            }
            .padding(.horizontal, Journal.Space.m)
            .padding(.bottom, Journal.Space.m)
        }
        // The split view's column-width request is advisory; the design's rail
        // is a fixed 232, so the view claims it outright as well.
        .frame(width: Journal.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Journal.paperDeep)
        .task { reload() }
        .onChange(of: model.activityRevision) { _, _ in reload() }
    }

    private func row(_ item: Item) -> some View {
        let isSelected = selected == item
        return Button {
            model.route = item.route
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Journal.ink : Journal.inkSoft)
                    .frame(width: 18)
                Text(item.title)
                    .font(.observed(13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Journal.ink : Journal.inkMid)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Journal.rule : Color.clear,
                in: RoundedRectangle(cornerRadius: Journal.Radius.field)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What FlowTrace holds, in the design's footer slot — with the true
    /// wording: the file is local and unencrypted, so it says "on this Mac".
    private var storage: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Storage")
                    .font(.caption())
                    .foregroundStyle(Journal.inkMid)
                Spacer()
                Text(holdings?.fileSizeLabel ?? (holdingsFailure == nil ? "—" : "unknown"))
                    .font(.caption(10.5, weight: .semibold))
                    .foregroundStyle(holdingsFailure == nil ? Journal.ink : Journal.danger)
            }
            if holdingsFailure != nil {
                LoadFailureLine(message: "Couldn't read the database")
            } else {
                Text("On this Mac · nothing leaves it")
                    .font(.caption(10))
                    .foregroundStyle(Journal.inkSoft)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Journal.wash.opacity(0.6), in: RoundedRectangle(cornerRadius: Journal.Radius.field))
    }

    private func reload() {
        let store = model.store
        Task.detached(priority: .utility) {
            let read = Result { try store.holdings() }
            await MainActor.run {
                switch read {
                case .success(let value):
                    holdings = value
                    holdingsFailure = nil
                case .failure(let error):
                    holdingsFailure = error.localizedDescription
                    Diagnostics.log("sidebar: reading holdings failed: \(error)")
                }
            }
        }
    }
}
