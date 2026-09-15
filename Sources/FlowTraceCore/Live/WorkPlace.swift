import Foundation

/// Where a running process is actually working, once you have discarded the
/// directories that are not places anyone works.
///
/// A census of running agents is not yet a list of projects. On a real machine
/// the raw reading contained a place called `/`, because a Codex process had
/// been started from the filesystem root; a place called `~`, because two
/// agents were launched from the home directory; and a place called `aum`,
/// which was a repository sitting in the Trash. All three appeared beside real
/// work, with real timestamps, and the last one invited the user to pick up a
/// project they had deliberately thrown away.
///
/// So a working directory has to earn the word "project" before it is shown as
/// one. What fails the test is not thrown away — the agent is still running and
/// saying otherwise would be a lie — it is just not allowed to claim a place.
public struct WorkPlace: Sendable, Hashable {
    /// The canonical repository root, or the working directory when the process
    /// is not in a repository.
    public var path: String
    /// What to call it.
    public var name: String
    /// Why this is not shown as a project, when it is not.
    public var rejection: Rejection?

    public var isProject: Bool { rejection == nil }

    /// The reasons a directory is not a place you are working. Each one was
    /// found in a real reading rather than imagined.
    public enum Rejection: String, Sendable, Hashable {
        /// The filesystem root, or another directory so high up that everything
        /// beneath it would be grouped into one meaningless pile.
        case notADirectoryAnyoneWorksIn
        /// The home directory itself. Agents get launched here constantly, and
        /// grouping them produces a "project" that is really "everything else".
        case homeDirectory
        /// Inside the Trash. The work was deliberately discarded; reminding
        /// somebody of it is the opposite of useful.
        case discarded
        /// Somewhere owned by the system rather than by the user.
        case systemDirectory

        public var explanation: String {
            switch self {
            case .notADirectoryAnyoneWorksIn: "started outside any project"
            case .homeDirectory: "started in your home folder"
            case .discarded: "in the Trash"
            case .systemDirectory: "outside your own folders"
            }
        }
    }

    /// Decides what a working directory is, given the repository root git
    /// reported for it (or nil when git found none).
    ///
    /// The repository root is preferred when there is one, so an agent in
    /// `tulu/frontend` and a server in `tulu/api` land in the same place. The
    /// rejections are then applied to whichever path won, because a repository
    /// in the Trash is still in the Trash.
    public static func resolve(
        workingDirectory: String,
        repositoryRoot: String?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> WorkPlace {
        let path = FilePathCanon.canonical(repositoryRoot ?? workingDirectory)
        let home = FilePathCanon.canonical(home)
        let name = SessionImporter.folderLabel(for: path)

        return WorkPlace(path: path, name: name, rejection: reject(path, home: home))
    }

    private static func reject(_ path: String, home: String) -> Rejection? {
        if path == "/" || path.isEmpty { return .notADirectoryAnyoneWorksIn }
        if path == home { return .homeDirectory }

        // Matched on whole path components so that a legitimate project called
        // `trash-panda` is not mistaken for something discarded.
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(".Trash") { return .discarded }

        guard path.hasPrefix(home + "/") else {
            // Outside the home directory. `/tmp`, `/private/var`, a mounted
            // volume, `/Applications` — none of them are somebody's project,
            // and an agent started in one is almost always a scratch run.
            return .systemDirectory
        }

        // Directly inside home, one level down, is fine: `~/venture` is a real
        // place. Two dotfile directories are not: `~/.Trash` is caught above,
        // and caches under `~/Library` are not work.
        if parts.contains("Library") { return .systemDirectory }
        return nil
    }
}
