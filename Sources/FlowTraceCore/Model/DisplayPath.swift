import Foundation

public extension String {
    /// `/Users/you/code/acme` → `~/code/acme`.
    ///
    /// Paths appear in proposal cards, thread detail, Settings and CLI output.
    /// Abbreviating in one place keeps them looking the same everywhere.
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}
