import SwiftUI

/// A read that didn't work, said out loud and left on the screen.
///
/// Toasts are for things you did — saved, forgotten, copied — and they are gone
/// in three seconds. A screen that could not load its data has to keep saying
/// so, or the failure becomes indistinguishable from an empty database: both
/// render as nothing, and one of them is a lie. Every screen that reads from
/// the store uses this for that case.
struct LoadFailureNotice: View {
    let message: String
    /// Present when the read is worth attempting again — most are.
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Journal.Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Journal.danger)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("FlowTrace couldn't read this from its database.")
                    .font(.observed(13, weight: .semibold))
                    .foregroundStyle(Journal.ink)
                Text(message)
                    .font(.observed(12))
                    .foregroundStyle(Journal.inkMid)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was changed or lost.")
                    .font(.caption())
                    .foregroundStyle(Journal.inkSoft)
            }

            Spacer(minLength: Journal.Space.s)

            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.plain)
                    .font(.observed(12, weight: .medium))
                    .foregroundStyle(Journal.pen)
            }
        }
        .padding(Journal.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card)
                .strokeBorder(Journal.danger.opacity(0.35), lineWidth: 1)
        )
    }
}

/// The same failure where there is only room for one line — the sidebar's
/// storage row, the menu-bar popover.
struct LoadFailureLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption(10))
        .foregroundStyle(Journal.danger)
    }
}
