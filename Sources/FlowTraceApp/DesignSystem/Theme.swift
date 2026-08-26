import SwiftUI
import FlowTraceCore

/// Layout and colour tokens.
///
/// Colours are derived from the system palette so light and dark mode both work
/// without a second set of definitions, and the window sits comfortably next to
/// native macOS apps rather than looking like a web page in a frame.
enum Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
    }

    enum Radius {
        static let card: CGFloat = 10
        static let chip: CGFloat = 5
    }

    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let subtleBorder = Color(nsColor: .separatorColor)
    static let pageBackground = Color(nsColor: .underPageBackgroundColor)

    static func statusColor(_ status: ThreadStatus) -> Color {
        switch status {
        case .active: .green
        case .paused: .orange
        case .completed: .secondary
        }
    }

    static func priorityColor(_ priority: Priority) -> Color {
        switch priority {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }

    /// How cold a piece of work is, at a glance.
    static func heatColor(days: Int) -> Color {
        switch days {
        case ..<7: .secondary
        case 7..<30: .orange
        default: .red
        }
    }
}

extension Date {
    /// "3d ago", "yesterday" — short enough to sit inside a card.
    var relativeShort: String {
        let days = Calendar.current.dateComponents([.day], from: self, to: Date()).day ?? 0
        switch days {
        case ..<0: return "just now"
        case 0:
            let hours = Calendar.current.dateComponents([.hour], from: self, to: Date()).hour ?? 0
            if hours < 1 { return "just now" }
            return "\(hours)h ago"
        case 1: return "yesterday"
        case 2...30: return "\(days)d ago"
        case 31...365: return "\(days / 30)mo ago"
        default: return "\(days / 365)y ago"
        }
    }
}

// MARK: - Shared components

struct SectionHeader: View {
    let title: String
    var count: Int?
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.cardBackground, in: Capsule())
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

/// A small labelled chip. Used for evidence, tags and status.
struct Chip: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
    }
}

struct StatusDot: View {
    let status: ThreadStatus
    var blocked: Bool = false

    var body: some View {
        Circle()
            .fill(blocked ? Color.red : Theme.statusColor(status))
            .frame(width: 7, height: 7)
    }
}

/// An empty state that says what to do next, not just that there's nothing here.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.xxl)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.m
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.subtleBorder, lineWidth: 0.5)
            )
    }
}

/// Labelled field used throughout the detail view and capture sheet.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .red : .green)
            Text(toast.message)
                .font(.system(size: 12))
                .lineLimit(2)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.subtleBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}
