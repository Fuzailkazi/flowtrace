import Foundation

/// Removes credential-shaped strings from text before it is stored or shown.
///
/// Prompts are the one free-text input FlowTrace reads, and free text contains
/// whatever the user pasted. A scan of `~/.claude/projects` on the machine this
/// was written on found five live API keys sitting in prompts — a Gemini key in
/// the very first prompt of one repository.
///
/// This matters most for the brief, which is injected into an agent's context: a
/// key that leaks there travels further than one sitting in a local database.
/// Redaction is therefore applied at the point text leaves the transcript, not at
/// the point it is displayed.
public enum Redaction {
    /// Each pattern is anchored on a distinctive prefix rather than on entropy.
    /// Guessing at "random-looking strings" flags commit hashes, UUIDs and
    /// minified code; provider prefixes do not.
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let sources: [(String, String)] = [
            ("api key", #"\bsk-[A-Za-z0-9_-]{16,}"#),
            ("api key", #"\bAIza[0-9A-Za-z_-]{30,}"#),
            ("api key", #"\bAQ\.[A-Za-z0-9_-]{20,}"#),
            ("token", #"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            ("token", #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#),
            ("aws key", #"\bAKIA[0-9A-Z]{16}\b"#),
            ("token", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#),
            ("connection string", #"\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s:/@]+:[^\s@]+@\S+"#),
            ("secret", #"\b[A-Z][A-Z0-9_]{3,}_(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS)\s*[=:]\s*\S{8,}"#),
            ("bearer token", #"\bBearer\s+[A-Za-z0-9._~+/-]{20,}"#),
            ("private key", #"-----BEGIN[A-Z ]*PRIVATE KEY-----"#),
        ]
        return sources.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    public struct Result: Equatable, Sendable {
        public var text: String
        public var redactionCount: Int
        public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Replaces each match with a short marker naming what was removed, so the
    /// sentence around it still reads: "update the chatgpt key with this key
    /// [api key removed]".
    public static func redact(_ text: String) -> Result {
        var working = text
        var count = 0

        for (name, regex) in patterns {
            var replaced = ""
            var lastEnd = working.startIndex
            let range = NSRange(working.startIndex..., in: working)

            regex.enumerateMatches(in: working, range: range) { match, _, _ in
                guard let match, let matchRange = Range(match.range, in: working) else { return }
                replaced += working[lastEnd..<matchRange.lowerBound]
                replaced += "[\(name) removed]"
                lastEnd = matchRange.upperBound
                count += 1
            }

            if count > 0 || lastEnd != working.startIndex {
                replaced += working[lastEnd...]
                working = replaced
            }
        }

        return Result(text: working, redactionCount: count)
    }

    /// True when redaction left nothing but markers and punctuation — a prompt
    /// that was only a pasted key says nothing about what the user was doing, so
    /// it should be dropped rather than shown as "[api key removed]".
    public static func isOnlyRedactions(_ result: Result) -> Bool {
        guard result.redactionCount > 0 else { return false }
        var stripped = result.text
        for name in ["api key", "token", "aws key", "connection string",
                     "secret", "bearer token", "private key"] {
            stripped = stripped.replacingOccurrences(of: "[\(name) removed]", with: "")
        }
        let remaining = stripped.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        return remaining.count < 8
    }
}
