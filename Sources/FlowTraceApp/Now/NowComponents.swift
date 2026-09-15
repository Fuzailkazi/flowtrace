import SwiftUI

/// The small pieces the Now screen is assembled from.
///
/// Kept beside the screen rather than in the design system because they encode
/// this page's particular rhythm — a section is an icon, a title and a quiet
/// right-hand caption; a card is white on paper with a shadow you can barely
/// see. If Timeline or Memories want the same shapes they should move up.

/// "N agent" / "N agents" — the one place plurals are spelled.
func nowCount(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// A section title in the design's voice: a soft symbol, a semibold title and,
/// on the right, a mono caption that says something true about the contents.
struct NowSectionHeader: View {
    let symbol: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: Journal.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Journal.inkSoft)
            Text(title)
                .font(.journalTitle(15))
                .foregroundStyle(Journal.ink)
            Spacer(minLength: Journal.Space.l)
            if let trailing {
                Text(trailing)
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)
            }
        }
    }
}

/// A filled chip: a browser's name, "Active project", "can't read tabs".
struct NowChip: View {
    let text: String
    var symbol: String?
    var tint: Color = Journal.inkMid
    var fill: Color = Journal.wash

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.caption())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(fill, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
    }
}

/// The accent-filled button: one per screen, for the thing you most likely
/// want to do next.
struct NowPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.observed(12, weight: .medium))
            .foregroundStyle(Journal.onPen)
            .padding(.horizontal, Journal.Space.l)
            .padding(.vertical, Journal.Space.s)
            .background(Journal.pen, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A square, quiet icon button that sits beside the primary one.
struct NowIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Journal.inkMid)
            .frame(width: 32, height: 32)
            .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The eyebrow dot. It breathes only while something is actually working, so
/// the motion means something; it holds still for anyone who has asked the
/// system to reduce motion.
struct NowPulsingDot: View {
    var color: Color
    var pulsing: Bool

    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear(perform: restart)
            .onChange(of: pulsing) { _, _ in restart() }
    }

    private func restart() {
        guard pulsing, !reduceMotion else {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { dimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

extension View {
    /// White on paper, softly lifted — the design's `surface-container-lowest`
    /// card with its `0 2px 12px rgba(0,0,0,0.03)` shadow.
    func nowCard(padding: CGFloat = Journal.Space.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Journal.Radius.card)
                    .fill(Journal.card)
                    .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
            )
    }
}
