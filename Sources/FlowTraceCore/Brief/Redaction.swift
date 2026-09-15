import Foundation

/// Removes credential-shaped strings from text before it is stored or shown.
///
/// Prompts are the one free-text input FlowTrace reads, and free text contains
/// whatever the user pasted. A scan of `~/.claude/projects` on the machine this
/// was written on found five live API keys sitting in prompts — a Gemini key in
/// the very first prompt of one repository.
///
/// Redaction is applied at the point text *enters* FlowTrace — in the agent
/// adapters as a transcript is parsed, and in the `Store` as a URL or title is
/// written — so every consumer downstream (the scan cache, proposals, threads,
/// the timeline, the search index, the brief, Now, the CLI) is clean by
/// construction rather than by remembering to filter.
public enum Redaction {
    /// Each pattern is anchored on a distinctive prefix rather than on entropy.
    /// Guessing at "random-looking strings" flags commit hashes, UUIDs and
    /// minified code; provider prefixes do not.
    ///
    /// **Order is part of the behaviour.** Patterns are applied in sequence, so
    /// the provider-prefix rules sit ahead of the generic `NAME=value` rule —
    /// otherwise `export STRIPE_SECRET_KEY=sk_live_…` would be labelled a
    /// "secret" and the more specific rule would never run. The full
    /// private-key block sits ahead of the header-only rule for the same reason.
    private static let patterns: [(name: String, regex: NSRegularExpression)] = {
        let sources: [(String, String)] = [
            // Stripe and the OpenAI family.
            ("api key", #"\bsk-[A-Za-z0-9_-]{16,}"#),
            ("api key", #"\bsk_(?:live|test)_[A-Za-z0-9]{16,}"#),
            ("api key", #"\brk_(?:live|test)_[A-Za-z0-9]{16,}"#),
            // Google.
            ("api key", #"\bAIza[0-9A-Za-z_-]{30,}"#),
            ("api key", #"\bAQ\.[A-Za-z0-9_-]{20,}"#),
            ("token", #"\bya29\.[A-Za-z0-9_-]{20,}"#),
            // GitHub: the classic prefixes and the fine-grained shape.
            ("token", #"\bgh[pousr]_[A-Za-z0-9]{20,}"#),
            ("token", #"\bgithub_pat_[A-Za-z0-9_]{20,}"#),
            // GitLab.
            ("token", #"\bglpat-[A-Za-z0-9_-]{20,}"#),
            // Slack.
            ("token", #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#),
            ("token", #"\bxapp-[A-Za-z0-9-]{10,}"#),
            // Hugging Face, npm, SendGrid.
            ("api key", #"\bhf_[A-Za-z0-9]{20,}"#),
            ("token", #"\bnpm_[A-Za-z0-9]{20,}"#),
            ("api key", #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#),
            // AWS.
            ("aws key", #"\bAKIA[0-9A-Z]{16}\b"#),
            // Anything shaped like a JWT.
            ("token", #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#),
            ("connection string", #"\b(?:postgres|postgresql|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s:/@]+:[^\s@]+@\S+"#),
            ("secret", #"\b[A-Z][A-Z0-9_]{3,}_(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIALS)\s*[=:]\s*\S{8,}"#),
            ("bearer token", #"\bBearer\s+[A-Za-z0-9._~+/-]{20,}"#),
            // The whole block first, so the body goes with the header; the
            // header-only rule stays as the fallback for a truncated paste.
            ("private key", #"-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----"#),
            ("private key", #"-----BEGIN[A-Z ]*PRIVATE KEY-----"#),
        ]
        return sources.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    /// Every marker this type can leave behind, derived from the patterns rather
    /// than listed again — a name that has to be repeated is a name that will be
    /// forgotten when a pattern is added.
    static var markerNames: Set<String> { Set(patterns.map(\.name)) }

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

            if lastEnd != working.startIndex {
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
        for name in markerNames {
            stripped = stripped.replacingOccurrences(of: "[\(name) removed]", with: "")
        }
        let remaining = stripped.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted
        )
        return remaining.count < 8
    }

    // MARK: - Addresses

    /// Query and fragment names whose value is always a credential.
    private static let alwaysBlank: Set<String> = [
        "token", "access_token", "id_token", "refresh_token",
        "api_key", "api-key", "apikey",
        "secret", "client_secret", "signature",
        "x-amz-signature", "x-amz-credential", "x-amz-security-token",
        "password", "passwd", "pwd",
        "auth", "authorization", "session", "sessionid", "sid",
    ]

    /// Names that are usually harmless but carry a credential when the value is
    /// long: `?key=name` is a sort order, `?key=<40 chars>` is not. `code` and
    /// `state` are deliberately absent — an OAuth callback is gone in a second
    /// and nobody writes a note about one, while `?code=404` and `?state=CA` are
    /// pages people do write about.
    private static let blankWhenLong: Set<String> = ["key", "sig"]
    private static let longEnough = 16

    private static let blanked = "removed"

    /// Blanks credential-shaped query and fragment values, keeping the name so
    /// the address stays recognisable: `…?token=removed&page=2`.
    ///
    /// Returns the input unchanged when nothing was blanked. That escape hatch
    /// is load-bearing beyond tidiness: an edit-free `URLComponents` round trip
    /// can still alter text — an empty item in `?a=b&&c=d` collapses, nil and
    /// empty values are asymmetric, IPv6 hosts get re-bracketed — and returning
    /// the original sidesteps all of it. Idempotent.
    public static func redactURL(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        var changed = false

        if components.password != nil, components.password != blanked {
            components.password = blanked
            changed = true
        }

        if let items = components.percentEncodedQueryItems {
            let cleaned = items.map { item -> URLQueryItem in
                guard shouldBlank(name: item.name, value: item.value) else { return item }
                changed = true
                return URLQueryItem(name: item.name, value: blanked)
            }
            if changed { components.percentEncodedQueryItems = cleaned }
        }

        // A fragment is only treated as parameters when it actually looks like
        // them. `#open-roles` is a heading, and blanking it would destroy the
        // one thing that made the address recognisable.
        if let fragment = components.percentEncodedFragment,
           let pairs = parameterPairs(in: fragment) {
            var fragmentChanged = false
            let rebuilt = pairs.map { pair -> String in
                guard shouldBlank(name: pair.name, value: pair.value) else {
                    return pair.value.map { "\(pair.name)=\($0)" } ?? pair.name
                }
                fragmentChanged = true
                return "\(pair.name)=\(blanked)"
            }
            if fragmentChanged {
                components.percentEncodedFragment = rebuilt.joined(separator: "&")
                changed = true
            }
        }

        guard changed, let rebuilt = components.string else { return url }
        return rebuilt
    }

    private static func shouldBlank(name: String, value: String?) -> Bool {
        guard let value, !value.isEmpty, value != blanked else { return false }
        let lowered = name.lowercased()
        if alwaysBlank.contains(lowered) { return true }
        return blankWhenLong.contains(lowered) && value.count >= longEnough
    }

    /// `k=v&k=v` as pairs, or nil when the string is not that shape.
    private static func parameterPairs(in fragment: String) -> [(name: String, value: String?)]? {
        guard fragment.contains("=") else { return nil }
        var pairs: [(name: String, value: String?)] = []
        for part in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            let halves = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = halves.first, !name.isEmpty else { return nil }
            pairs.append((String(name), halves.count > 1 ? String(halves[1]) : nil))
        }
        return pairs.isEmpty ? nil : pairs
    }
}
