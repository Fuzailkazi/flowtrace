import Foundation

/// Canonical filesystem paths.
///
/// Paths reach FlowTrace from several places that disagree with each other:
/// `git rev-parse` returns a fully resolved path, while a folder picker, a CLI
/// argument or an agent transcript may hand back a symlinked one. On macOS the
/// common case is `/var/...` versus `/private/var/...`, and Foundation's
/// `resolvingSymlinksInPath()` deliberately leaves that pair alone — so two
/// spellings of the same directory would compare as different repositories.
///
/// Everything that stores or compares a path goes through here first.
public enum FilePathCanon {
    public static func canonical(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        // The path may not exist (a repository that has since been deleted);
        // fall back to Foundation's resolution rather than dropping it.
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    public static func canonical(_ paths: some Sequence<String>) -> Set<String> {
        Set(paths.map(canonical))
    }
}
