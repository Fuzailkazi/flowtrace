import Foundation

/// The project an editor has in front, read from the editor's own state file.
public struct Place: Sendable, Equatable {
    /// Repository root, canonical — the same key `LiveProject` and `ProjectNote` use.
    public var root: String
    /// "flowtrace" — what a person calls it. From `SessionImporter.folderLabel`,
    /// deliberately: Now already labels this place that way, and two names for
    /// one place is worse than an imperfect name.
    public var name: String
    /// Which editor said so, for the header line ("Cursor's current window").
    public var editor: String

    public init(root: String, name: String, editor: String) {
        self.root = root
        self.name = name
        self.editor = editor
    }
}

/// Editors that keep a readable record of their focused window.
///
/// All of these are VS Code or a fork of it, so one parser serves them all.
/// Adding another is a line in this list, which is why it is data.
public struct EditorFamily: Sendable {
    public var bundleIdentifiers: Set<String>
    /// Directory under ~/Library/Application Support.
    public var supportDirectory: String
    /// What to call it in the panel. `localizedName` is "Code" for VS Code,
    /// which would render "Code · Code's current window".
    public var displayName: String

    /// Both identifiers below were read from the installed apps' Info.plist on
    /// the author's machine. Other forks are omitted on purpose: an
    /// unverified identifier is silent breakage, and VSCodium in particular
    /// ships `com.vscodium` on release builds, not the oss-dev identifier that
    /// is easy to find by searching. Add one only after checking its plist.
    public static let all: [EditorFamily] = [
        EditorFamily(
            bundleIdentifiers: ["com.microsoft.VSCode"],
            supportDirectory: "Code", displayName: "VS Code"
        ),
        EditorFamily(
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            supportDirectory: "Cursor", displayName: "Cursor"
        ),
    ]

    public static func matching(bundleIdentifier: String?) -> EditorFamily? {
        guard let bundleIdentifier else { return nil }
        return all.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }
}

/// Which window an editor has in front, asked of the editor rather than guessed.
///
/// VS Code writes its window state to
/// `~/Library/Application Support/Code/User/globalStorage/storage.json`, and
/// Cursor — a fork — writes the same shape under its own support directory.
/// That file needs no permission, and it answers the question process
/// inspection cannot: not "which projects does this app have open" but *which
/// window is in front*. Two earlier designs ranked terminals and processes by
/// tty timestamps instead, and both were measurably wrong at the top of the
/// ranking.
///
/// Everything here is a pure function of a file's contents plus a freshness
/// check. There is no clock to inject and no polling: the panel owns the wait
/// for its own blur (see the design's §2), because Core has no business
/// watching a clock.
public enum EditorPlace {
    /// `~/Library/Application Support`, where every supported editor keeps its
    /// support directory.
    ///
    /// Defined once and named, rather than inlined at the call sites: the
    /// capture panel stats the same file to know when its own blur has landed,
    /// and a second spelling of this path would be a bug nobody notices.
    public static let defaultSupport: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")

    /// Where the editor's state file lives, so the caller can check its
    /// freshness before and after triggering a write. See the design's §2 —
    /// the caller owns the waiting, because Core has no business polling a
    /// clock.
    public static func storageURL(for family: EditorFamily, support: URL) -> URL {
        support
            .appendingPathComponent(family.supportDirectory)
            .appendingPathComponent("User/globalStorage/storage.json")
    }

    /// Reads the file and resolves the focused window's repository.
    ///
    /// `staleness` refuses a value left over from a previous session. It is
    /// tight (two minutes) for a reason that is easy to get wrong: the file's
    /// mtime is "when a window last lost focus", *not* the age of the value.
    /// VS Code loads the previous session's state at launch and does not
    /// rewrite it until the first blur, so a loose bound would happily return
    /// yesterday's project. With the caller's wait the file is always seconds
    /// old whenever the answer is trustworthy, so tightness is free — and it
    /// is the only thing that refuses the two genuinely stale states: a
    /// carried-over session, and the editor frontmost with no windows open.
    ///
    /// A folder that is not a repository is still an answer — a note about a
    /// directory beats a note about an app — but a folder that no longer
    /// exists is not, so the resolved root must be there to be returned.
    ///
    /// This is one file read *plus* one subprocess (`GitProbe.topLevel` forks
    /// `git rev-parse`), so it belongs off the main actor.
    public static func place(
        forBundleIdentifier id: String?,
        support: URL = defaultSupport,
        staleness: TimeInterval = 120,
        git: GitProbe = GitProbe()
    ) -> Place? {
        guard let family = EditorFamily.matching(bundleIdentifier: id) else { return nil }

        let url = storageURL(for: family, support: support)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap({ $0[.modificationDate] as? Date }),
            Date().timeIntervalSince(modified) <= staleness
        else { return nil }

        guard let data = try? Data(contentsOf: url),
              let folder = lastActiveFolder(inStorageJSON: data)
        else { return nil }

        // `GitProbe.topLevel` canonicalises its own result; the fallback has to
        // be run through `FilePathCanon` here, or one place would be stored
        // under two spellings.
        let root = git.topLevel(of: folder) ?? FilePathCanon.canonical(folder)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        return Place(
            root: root,
            name: SessionImporter.folderLabel(for: root),
            editor: family.displayName
        )
    }

    // MARK: - The testable half

    /// The focused window's folder path, from a `globalStorage/storage.json`.
    ///
    /// Only `windowsState.lastActiveWindow.folder` is read. `openedWindows` is
    /// ignored: it is the set of projects open — the ambiguity this design
    /// exists to avoid — it is empty whenever only one window is open, and its
    /// order is registration order, not recency. It carries no answer.
    ///
    /// What the format actually does, and what that costs:
    /// - `folder` is a URL string and **the scheme must be `file`**. A remote
    ///   window writes `vscode-remote://ssh-remote+host/home/x/proj` or a
    ///   dev-container URI, whose `.path` is a plausible-looking local path
    ///   that is not on this machine. Anything but `file` yields nil.
    /// - The path is percent-encoded (`file:///Users/dev/my%20project`);
    ///   decoding comes free from `URL.path`.
    /// - A multi-root workspace window carries `workspaceIdentifier` and no
    ///   `folder`, and yields nil rather than a guess: a `.code-workspace`
    ///   names several roots in an order that means nothing, and labelling
    ///   every capture with an arbitrary member is the failure two earlier
    ///   designs were rejected for. An untitled window has neither key.
    /// - Anything malformed yields nil rather than throwing. The editor writes
    ///   this file atomically (temp file plus rename), so a torn read is not
    ///   actually possible and this is belt-and-braces.
    public static func lastActiveFolder(inStorageJSON data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let windows = root["windowsState"] as? [String: Any],
              let lastActive = windows["lastActiveWindow"] as? [String: Any],
              let folder = lastActive["folder"] as? String,
              let url = URL(string: folder),
              url.scheme == "file"
        else { return nil }

        let path = url.path
        return path.isEmpty ? nil : path
    }
}
