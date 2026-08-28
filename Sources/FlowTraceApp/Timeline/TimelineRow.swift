import SwiftUI
import FlowTraceCore

/// One line of the day.
///
/// Two voices, visually separated: what the machine observed is set in the system
/// sans; what you wrote is set in serif italic. That split is the whole difference
/// between reading a log and reading a journal.
struct TimelineRow: View {
    let event: ActivityEvent
    var onSave: (String) -> Void
    var onDelete: () -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Journal.Space.m) {
            Text(event.startedAt, format: .dateTime.hour().minute())
                .font(.observed(11.5))
                .monospacedDigit()
                .foregroundStyle(Journal.inkSoft)
                .frame(width: 46, alignment: .trailing)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                header
                reason
            }
        }
        .padding(.vertical, Journal.Space.m)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(event.isUnexplained ? "Add a reason" : "Edit the reason") { beginEditing() }
            if let url = event.url {
                Button("Open") { NSWorkspace.shared.open(URL(string: url)!) }
            }
            Divider()
            Button("Forget this", role: .destructive, action: onDelete)
        }
    }

    // MARK: - What the machine saw

    private var header: some View {
        HStack(spacing: Journal.Space.s) {
            Text(event.appName)
                .font(.observed(13.5, weight: .semibold))
                .foregroundStyle(Journal.ink)

            if let target = event.target, !target.isEmpty {
                Text("·").foregroundStyle(Journal.ruleFirm)
                Text(target)
                    .font(.observed(13.5))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if event.kind == .agentSession {
                Text("session")
                    .font(.observed(10.5, weight: .medium))
                    .foregroundStyle(Journal.pen)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Journal.penSoft, in: RoundedRectangle(cornerRadius: 4))
            }

            Spacer(minLength: Journal.Space.s)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Journal.inkSoft)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Forget this")
            }

            Text(event.durationLabel)
                .font(.observed(11))
                .foregroundStyle(Journal.inkSoft)
        }
    }

    // MARK: - Why you were there

    @ViewBuilder
    private var reason: some View {
        if isEditing {
            editor
        } else if let note = event.note, !note.isEmpty {
            Text("“\(note)”")
                .font(.yourWords(15.5))
                .foregroundStyle(Journal.ink)
                .textSelection(.enabled)
                .onTapGesture(count: 2) { beginEditing() }
        } else if let summary = machineSummary {
            Text(summary)
                .font(.observed(13))
                .foregroundStyle(Journal.inkMid)
                .lineLimit(2)
        } else {
            unexplained
        }
    }

    /// The prompt is the amber thing, and amber means only this.
    private var unexplained: some View {
        Button(action: beginEditing) {
            HStack(spacing: Journal.Space.s) {
                Circle().fill(Journal.amber).frame(width: 6, height: 6)
                Text("why did you open this?")
                    .font(.yourWords(15))
                    .foregroundStyle(Journal.amber)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Journal.amberSoft.opacity(isHovering ? 1 : 0.72),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        HStack(spacing: Journal.Space.s) {
            TextField("why did you open this?", text: $draft)
                .textFieldStyle(.plain)
                .font(.yourWords(15.5))
                .foregroundStyle(Journal.ink)
                .focused($focused)
                .onSubmit(commit)

            Button("Save", action: commit)
                .buttonStyle(.plain)
                .font(.observed(11, weight: .medium))
                .foregroundStyle(Journal.pen)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(Journal.pen, lineWidth: 1)
        )
        .onExitCommand { isEditing = false }
    }

    /// For things that explain themselves — an agent session already knows what
    /// it was about, and a repository knows what state it is in.
    private var machineSummary: String? {
        switch event.kind {
        case .agentSession:
            // The duration column already carries the message count.
            let about = event.metadata["about"] ?? ""
            return about.isEmpty ? event.metadata["asked"]?.split(separator: "\n").last.map(String.init) : about
        case .git:
            return event.metadata["summary"]
        default:
            return nil
        }
    }

    private func beginEditing() {
        draft = event.note ?? ""
        isEditing = true
        focused = true
    }

    private func commit() {
        onSave(draft)
        isEditing = false
    }
}
