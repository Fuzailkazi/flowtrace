import Foundation
import Security

/// The shared secret the browser extension and CLI present to the local server.
///
/// It lives in the login keychain rather than on disk: it is a credential, and
/// anything that can read a plain file in Application Support could otherwise
/// post captures into the user's database.
public enum LocalCredentials {
    private static let service = "ai.flowtrace.FlowTrace"
    private static let account = "local-api-token"

    /// Where the token ended up, so Settings can tell the user the truth.
    public enum Storage: String, Sendable {
        case keychain
        case file
    }

    public private(set) nonisolated(unsafe) static var storage: Storage = .keychain

    /// The current token, generating and storing one on first use.
    ///
    /// The login keychain is the right home for a credential, but it isn't
    /// always reachable — a locked keychain, an SSH session, or a headless run
    /// all return `errSecUserCanceled` or `errSecInteractionNotAllowed`. Rather
    /// than take the whole capture endpoint down with it, FlowTrace falls back
    /// to a 0600 file in its own support directory and says so in Settings.
    public static func token() throws -> String {
        if let fromKeychain = (try? read()) ?? nil { storage = .keychain; return fromKeychain }
        if let existing = readFile() { storage = .file; return existing }

        let generated = generate()
        do {
            try write(generated)
            storage = .keychain
        } catch {
            try writeFile(generated)
            storage = .file
        }
        return generated
    }

    /// Replaces the token. Any extension still holding the old one stops working,
    /// which is the point.
    @discardableResult
    public static func regenerate() throws -> String {
        let generated = generate()
        try? FileManager.default.removeItem(at: tokenFileURL)
        do {
            try write(generated)
            storage = .keychain
        } catch {
            try writeFile(generated)
            storage = .file
        }
        return generated
    }

    private static var tokenFileURL: URL {
        FlowTraceDatabase.supportDirectory.appendingPathComponent("api-token")
    }

    private static func readFile() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func writeFile(_ token: String) throws {
        try FileManager.default.createDirectory(
            at: FlowTraceDatabase.supportDirectory, withIntermediateDirectories: true
        )
        try Data(token.utf8).write(to: tokenFileURL, options: .atomic)
        // Owner read/write only — it is a credential, not configuration.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path
        )
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LocalServerError.keychain(status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ token: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalServerError.keychain(status) }
    }

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
    case keychain(OSStatus)
    case couldNotBind(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Keychain error \(status) while handling the local API token."
        case .couldNotBind(let detail):
            "Couldn't start the local capture endpoint: \(detail)"
        }
    }
}
