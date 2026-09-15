import SwiftUI
import AppKit
import FlowTraceCore

/// One card of the day.
///
/// Two voices, visually separated: what the machine observed is set in the system
/// sans; what you wrote is set in italic, in its own band. That split is the whole
/// difference between reading a log and reading a journal.
struct TimelineRow: View {
    let event: ActivityEvent
    /// Briefly true after the row was pointed at from elsewhere.
    var isHighlighted = false
    var onSave: (String) -> Void
    var onDelete: () -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Journal.Space.l) {
            gutter
            card
        }
        .padding(.vertical, Journal.Space.s)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(event.isUnexplained ? "Add a reason" : "Edit the reason") { beginEditing() }
            if let url = event.url, let link = URL(string: url) {
                Button("Open") { NSWorkspace.shared.open(link) }
            }
            Divider()
            Button("Forget this", role: .destructive, action: onDelete)
        }
    }

    // MARK: - When

    private var gutter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(event.startedAt, format: .dateTime.hour().minute())
                .font(.mono(12))
                .foregroundStyle(Journal.ink)
            if !event.durationLabel.isEmpty {
                Text(event.durationLabel)
                    .font(.caption(9.5))
                    .foregroundStyle(Journal.inkSoft)
                    .lineLimit(1)
            }
        }
        .frame(width: 64, alignment: .trailing)
        .padding(.top, Journal.Space.l + 2)
    }

    // MARK: - What the machine saw

    private var card: some View {
        VStack(alignment: .leading, spacing: Journal.Space.m) {
            header

            if let summary = machineSummary, !summary.isEmpty {
                Text(summary)
                    .font(.observed(13))
                    .foregroundStyle(Journal.inkMid)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = event.url, let link = URL(string: url) {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 9.5))
                        Text(url)
                            .font(.mono(11, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(Journal.inkSoft)
                }
                .buttonStyle(.plain)
                .help("Open")
            }

            reason
        }
        .padding(Journal.Space.l + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHighlighted ? Journal.penSoft : Journal.card,
            in: RoundedRectangle(cornerRadius: Journal.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.card)
                .strokeBorder(isHighlighted ? Journal.pen : Color.clear, lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovering ? 0.05 : 0.03), radius: 6, y: 2)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Journal.Space.s) {
            Image(systemName: kindSymbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Journal.pen)
                .frame(width: 20, height: 20)
                .background(Journal.wash, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))

            Text(title)
                .font(.observed(15, weight: .semibold))
                .foregroundStyle(Journal.ink)
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer(minLength: Journal.Space.s)

            HStack(spacing: 5) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption(10))
                        .foregroundStyle(Journal.inkMid)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(Journal.wash, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .layoutPriority(1)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Journal.inkSoft)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Forget this")
            }
        }
    }

    /// What the entry was: the window or repository first, then the project it
    /// was in, then the bare app when that's all we know.
    private var title: String {
        if let target = event.target, !target.isEmpty { return target }
        if let place = event.metadata["place"], !place.isEmpty { return place }
        return event.appName
    }

    /// The app, the site, and — after `target`, never before it — the place.
    private var chips: [String] {
        var out = [event.appName]
        if let url = event.url, let host = URL(string: url)?.host, host != event.appName {
            out.append(host)
        }
        if let target = event.target, !target.isEmpty,
           let place = event.metadata["place"], !place.isEmpty, place != target {
            out.append(place)
        }
        return out
    }

    private var kindSymbol: String {
        switch event.kind {
        case .app: "macwindow"
        case .browserTab: "globe"
        case .agentSession: "terminal"
        case .git: "arrow.triangle.branch"
        }
    }

    // MARK: - Why you were there

    @ViewBuilder
    private var reason: some View {
        if isEditing {
            noteBand { editor }
        } else if let note = event.note, !note.isEmpty {
            noteBand {
                Text(note)
                    .font(.yourWords(15))
                    .foregroundStyle(Journal.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onTapGesture(count: 2) { beginEditing() }
        } else {
            unexplained
        }
    }

    /// The design's "User Note" block: a quiet band with your words in it.
    private func noteBand<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Journal.pen)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR NOTE")
                    .font(.caption(9.5))
                    .tracking(1.0)
                    .foregroundStyle(Journal.inkSoft)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Journal.Space.m)
        .background(Journal.paperDeep, in: RoundedRectangle(cornerRadius: Journal.Radius.field))
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
                in: RoundedRectangle(cornerRadius: Journal.Radius.field)
            )
        }
        .buttonStyle(.plain)
    }

    private var editor: some View {
        HStack(spacing: Journal.Space.s) {
            TextField("why did you open this?", text: $draft)
                .textFieldStyle(.plain)
                .font(.yourWords(15))
                .foregroundStyle(Journal.ink)
                .focused($focused)
                .onSubmit(commit)

            Button("Save", action: commit)
                .buttonStyle(.plain)
                .font(.observed(11, weight: .medium))
                .foregroundStyle(Journal.pen)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Journal.card, in: RoundedRectangle(cornerRadius: Journal.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Journal.Radius.chip).strokeBorder(Journal.pen, lineWidth: 1)
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
