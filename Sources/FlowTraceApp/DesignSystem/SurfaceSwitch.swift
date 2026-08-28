import SwiftUI

/// Moves between the two surfaces: what's happening now, and the day you can read.
///
/// Lives in the page header rather than the toolbar. A `.segmented` picker in a
/// macOS toolbar renders as an underlined tab strip that reads as half-drawn, and
/// the toolbar had nothing else in it — so the switch sits with the title it
/// belongs to, in the same palette as everything else.
struct SurfaceSwitch: View {
    @Bindable var model: AppModel

    private var showingToday: Bool { model.route == .timeline }

    var body: some View {
        HStack(spacing: 2) {
            segment("Now", isSelected: !showingToday) { model.route = .now }
            segment("Today", isSelected: showingToday) { model.route = .timeline }
        }
        .padding(2)
        .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(Journal.rule, lineWidth: 0.5)
        )
    }

    private func segment(
        _ title: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.observed(11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Journal.ink : Journal.inkSoft)
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5).fill(Journal.card)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
