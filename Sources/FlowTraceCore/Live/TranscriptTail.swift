import Foundation

/// Reads the last thing the user typed, without reading the whole transcript.
///
/// Transcripts run to megabytes and the Now screen refreshes continuously, so
/// reading each one end to end cost two seconds across eleven agents — nearly
/// all of it spent parsing history nobody asked for. Only the tail is read, and
/// it widens once if the last prompt is not in it: a long agent turn can put
/// megabytes of tool output between you and the last thing you said.
/// The last thing a *person* said, and when they said it.
///
/// The "when" is the load-bearing half. FlowTrace used a transcript's file
/// modification time as "last activity", which is the moment an agent last
/// wrote — not the moment a human was last here. Measured on a real machine,
/// thirty of forty-four projects had files newer than their last human turn by
/// more than an hour, and the worst was sixty days out: a project abandoned in
/// July whose file had been touched half an hour ago by a background agent, so
/// the one screen that exists to say "you forgot this" called it active.
struct HumanTurn {
    var text: String
    var at: Date?
}

enum TranscriptTail {
    static func read(path: String, scan: (Data) -> HumanTurn?) -> HumanTurn? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        var last: HumanTurn?
        for tailBytes in [512 * 1024, 4 * 1024 * 1024] {
            try? handle.seek(toOffset: UInt64(max(0, size - tailBytes)))
            guard let data = try? handle.readToEnd() else { break }
            last = scan(data)
            if last != nil || tailBytes >= size { break }
        }
        return last
    }

    /// Prompts are free text and routinely contain pasted keys, so nothing
    /// leaves here unredacted. A prompt that is nothing but redactions is
    /// dropped rather than shown as a row of markers.
    static func present(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // A dragged file pastes its path as the prompt; the sentence after it
        // is the part worth showing.
        let stripped = AgentSession.withoutLeadingPath(raw)
        let redacted = Redaction.redact(stripped.isEmpty ? raw : stripped)
        guard !Redaction.isOnlyRedactions(redacted), !redacted.isEmpty else { return nil }
        return AgentSession.condense(redacted.text, limit: 90)
    }
}

public enum ClaudeTail {
    static func lastTurn(in path: String) -> HumanTurn? {
        TranscriptTail.read(path: path, scan: scan)
    }

    static func lastPrompt(in path: String) -> String? {
        TranscriptTail.present(lastTurn(in: path)?.text)
    }

    /// The first line of a tail is very likely truncated mid-JSON; parsing
    /// simply fails on it and it is skipped, which is what is wanted.
    static func scan(_ data: Data) -> HumanTurn? {
        var last: HumanTurn?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = String(line)
            guard line.contains("\"type\":\"user\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["isSidechain"] as? Bool != true,
                  object["isMeta"] as? Bool != true,
                  let text = ClaudeCodeAdapter.userText(from: object["message"]),
                  AgentSession.isSubstantive(text),
                  !isMachineAuthored(text)
            else { continue }
            last = HumanTurn(
                text: text,
                at: (object["timestamp"] as? String).flatMap(ISO8601.parse)
            )
        }
        return last
    }

    /// Turns that arrive in the user's slot without a user.
    ///
    /// Scheduled tasks, hooks and background-task notifications are injected as
    /// user messages. They are long enough to pass every "is this substantive"
    /// test and they are not something anybody typed. On the machine this was
    /// measured on, six of forty-four projects had one of these as the most
    /// recent thing in the user's slot.
    public static func isMachineAuthored(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("<") else { return false }
        return ["<scheduled-task", "<task-notification", "<system-reminder",
                "<command-name", "<local-command", "<user-prompt-submit-hook"]
            .contains { head.hasPrefix($0) }
    }
}

enum CodexTail {
    static func lastTurn(in path: String) -> HumanTurn? {
        TranscriptTail.read(path: path, scan: scan)
    }

    static func lastPrompt(in path: String) -> String? {
        TranscriptTail.present(lastTurn(in: path)?.text)
    }

    /// Codex wraps everything in `payload`. A user turn is a `user_message`
    /// whose `message` is the text; Codex also injects its own environment
    /// preamble as a user message, which is not something anybody typed.
    static func scan(_ data: Data) -> HumanTurn? {
        var last: HumanTurn?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = String(line)
            guard line.contains("user_message") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let text = payload["message"] as? String,
                  !text.hasPrefix("<environment_context>"),
                  !text.hasPrefix("<user_instructions>"),
                  AgentSession.isSubstantive(text),
                  !ClaudeTail.isMachineAuthored(text)
            else { continue }
            last = HumanTurn(
                text: text,
                at: (object["timestamp"] as? String).flatMap(ISO8601.parse)
            )
        }
        return last
    }
}
