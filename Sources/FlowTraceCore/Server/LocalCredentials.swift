import Foundation
import Security

/// The shared secret the browser extension and CLI present to the local server.
///
/// Stored as an owner-only (0600) file next to the database rather than in the
/// keychain, for two reasons:
///
/// 1. **It prompts.** A keychain ACL is bound to the app's code signature. An
///    ad-hoc signed build changes identity on every rebuild, so macOS puts up
///    "FlowTrace wants to use your confidential information" at launch — a dialog
///    the user cannot meaningfully act on and which blocks the window.
/// 2. **It protects nothing extra.** This token guards a loopback endpoint whose
///    only power is writing to `flowtrace.sqlite` — which sits unencrypted in the
///    same directory. Anything able to read the token file can already read the
///    database. Keychain-protecting the key to an unlocked door is ceremony with
///    a real usability cost.
///
/// It is a localhost capability token, not a password, and it is treated as one.
public enum LocalCredentials {
    /// The current token, generating and storing one on first use.
    public static func token() throws -> String {
        if let existing = read() { return existing }
        let generated = generate()
        try write(generated)
        return generated
    }

    /// Replaces the token. Any extension still holding the old one stops working,
    /// which is the point.
    @discardableResult
    public static func regenerate() throws -> String {
        let generated = generate()
        try write(generated)
        return generated
    }

    public static var tokenFileURL: URL {
        FlowTraceDatabase.supportDirectory.appendingPathComponent("api-token")
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func read() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func write(_ token: String) throws {
        try FileManager.default.createDirectory(
            at: FlowTraceDatabase.supportDirectory, withIntermediateDirectories: true
        )
        try Data(token.utf8).write(to: tokenFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path
        )
    }

    // MARK: - Port advertisement

    /// Where the running app advertises its port, so the CLI and extension can
    /// find it without hardcoding one.
    public static var portFileURL: URL {
        FlowTraceDatabase.supportDirectory.appendingPathComponent("port")
    }

    public static func publish(port: UInt16) {
        try? FileManager.default.createDirectory(
            at: FlowTraceDatabase.supportDirectory, withIntermediateDirectories: true
        )
        try? Data("\(port)".utf8).write(to: portFileURL)
    }

    public static func publishedPort() -> UInt16? {
        guard let data = try? Data(contentsOf: portFileURL),
              let value = UInt16(String(decoding: data, as: UTF8.self)
                  .trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return value
    }

    public static func clearPublishedPort() {
        try? FileManager.default.removeItem(at: portFileURL)
    }
}

public enum LocalServerError: LocalizedError {
    case couldNotBind(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotBind(let detail):
            "Couldn't start the local capture endpoint: \(detail)"
        }
    }
}
