import Foundation

/// Git state for one repository at one moment.
public struct GitState: Hashable, Sendable {
    public var topLevel: String
    public var repositoryName: String
    public var branch: String
    public var headSha: String?
    public var headDate: Date?
    public var dirtyFileCount: Int
    public var commitsAhead: Int
    public var commitsBehind: Int

    /// The files you were actually editing, most-changed first.
    ///
    /// This is the single most recognisable thing about a paused piece of work —
    /// "IntentTrace.jsx, intent.js" says what a file *count* never can.
    public var changedFiles: [String]
    /// Subject line of the last commit. Describes the work in your own words.
    public var lastCommitSubject: String?

    public var daysSinceLastCommit: Int {
        guard let headDate else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: headDate, to: Date()).day ?? 0)
    }

    public var isDirty: Bool { dirtyFileCount > 0 }

    public func snapshot(at date: Date = Date()) -> RepoSnapshot {
        RepoSnapshot(
            repositoryPath: topLevel,
            branch: branch,
            headSha: headSha,
            dirtyFileCount: dirtyFileCount,
            commitsAhead: commitsAhead,
            commitsBehind: commitsBehind,
            capturedAt: date
        )
    }
}

/// Reads git state without ever mutating a repository.
///
/// Only inspection commands are used: `rev-parse`, `status --porcelain`, `log -1`
/// and `rev-list --count`. FlowTrace never checks out, stashes, commits or fetches.
public struct GitProbe: Sendable {
    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    /// Resolves any path inside a repository to the repository root.
    ///
    /// This is what collapses several agent working directories that are really
    /// subfolders of one repo into a single piece of work.
    public func topLevel(of path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        let result = Shell.run(gitPath, ["rev-parse", "--show-toplevel"], cwd: path)
        guard result.ok else { return nil }
        let top = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : FilePathCanon.canonical(top)
    }

    public func probe(_ repositoryPath: String) -> GitState? {
        guard let top = topLevel(of: repositoryPath) else { return nil }

        let branchResult = Shell.run(gitPath, ["rev-parse", "--abbrev-ref", "HEAD"], cwd: top)
        let branch = branchResult.ok
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "HEAD"

        let status = Shell.run(gitPath, ["status", "--porcelain"], cwd: top)
        let statusLines = status.ok
            ? status.stdout.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
            : []
        let dirtyCount = statusLines.count
        // Porcelain lines are "XY path"; keep the path, drop the status flags.
        let changedFiles = statusLines.compactMap { line -> String? in
            let trimmed = line.dropFirst(3)
            guard !trimmed.isEmpty else { return nil }
            // Renames appear as "old -> new"; the new name is what matters.
            if let arrow = trimmed.range(of: " -> ") {
                return String(trimmed[arrow.upperBound...])
            }
            return String(trimmed)
        }

        var headSha: String?
        var headDate: Date?
        var headSubject: String?
        let log = Shell.run(gitPath, ["log", "-1", "--format=%H%n%ct%n%s"], cwd: top)
        if log.ok {
            let lines = log.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2 {
                headSha = String(lines[0])
                if let seconds = TimeInterval(lines[1]) {
                    headDate = Date(timeIntervalSince1970: seconds)
                }
            }
            if lines.count >= 3 {
                let subject = String(lines[2]).trimmingCharacters(in: .whitespaces)
                headSubject = subject.isEmpty ? nil : subject
            }
        }

        let (ahead, behind) = aheadBehind(top)

        return GitState(
            topLevel: top,
            repositoryName: URL(fileURLWithPath: top).lastPathComponent,
            branch: branch,
            headSha: headSha,
            headDate: headDate,
            dirtyFileCount: dirtyCount,
            commitsAhead: ahead,
            commitsBehind: behind,
            changedFiles: changedFiles,
            lastCommitSubject: headSubject
        )
    }

    /// Commits on the current branch versus its upstream. Returns zeros when the
    /// branch has no upstream — an unpushed branch is reported by `hasUpstream`.
    private func aheadBehind(_ top: String) -> (ahead: Int, behind: Int) {
        let result = Shell.run(
            gitPath,
            ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
            cwd: top
        )
        guard result.ok else { return (0, 0) }
        let parts = result.stdout
            .split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == " " })
            .compactMap { Int($0) }
        guard parts.count >= 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    public func hasUpstream(_ repositoryPath: String) -> Bool {
        Shell.run(
            gitPath,
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
            cwd: repositoryPath
        ).ok
    }
}
