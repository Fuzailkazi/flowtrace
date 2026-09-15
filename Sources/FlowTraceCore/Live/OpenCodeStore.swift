import Foundation
import GRDB

/// Reads OpenCode's own session store.
///
/// OpenCode keeps its sessions in SQLite with a `directory` column, which makes
/// it the one agent of the three that states where its work happened instead of
/// encoding it in a path slug or a rollout header. Read-only, in place, nothing
/// copied and nothing written: this is somebody else's database and FlowTrace
/// is a guest in it.
///
/// Every failure here returns nothing rather than throwing. The database can be
/// absent, mid-write, or a schema FlowTrace has never seen, and none of those
/// are worth failing a live reading over — "no history for this agent" is a
/// state the row already knows how to show.
public enum OpenCodeStore {
    /// Where OpenCode keeps its store, so Settings can name the file the
    /// switch is about rather than asking for trust in the abstract.
    public static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultDatabase.path)
    }

    /// The newest live session per directory.
    ///
    /// Archived sessions are skipped: OpenCode marks a session archived when
    /// the user is finished with it, and resurfacing finished work as
    /// "forgotten" is precisely the false positive worth avoiding.
    static func sessionsByDirectory(at url: URL) -> [String: TranscriptIndex.Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else {
            return [:]
        }

        let rows: [Row]? = try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, directory, title, time_updated
                FROM session
                WHERE time_archived IS NULL AND directory IS NOT NULL
                ORDER BY time_updated DESC
                """)
        }
        guard let rows else { return [:] }

        var newest: [String: TranscriptIndex.Entry] = [:]
        for row in rows {
            guard let directory: String = row["directory"], !directory.isEmpty,
                  let updated: Int64 = row["time_updated"]
            else { continue }

            let key = FilePathCanon.canonical(directory)
            // Rows arrive newest first, so the first one seen for a directory
            // wins and the rest are older sessions in the same place.
            guard newest[key] == nil else { continue }

            // OpenCode stores milliseconds since the epoch.
            let modifiedAt = Date(timeIntervalSince1970: Double(updated) / 1_000)
            let title: String? = row["title"]
            newest[key] = TranscriptIndex.Entry(
                sessionId: row["id"],
                modifiedAt: modifiedAt,
                // OpenCode records only when the session was updated, with no
                // way to tell an agent's write from a person's. Left unknown
                // rather than guessed — the fallback treats it as unmeasured.
                lastHumanAt: nil,
                // The session title is OpenCode's own summary of the work,
                // which is a better line than anything FlowTrace could infer —
                // but it is still text from outside, so it is redacted like a
                // prompt.
                lastPrompt: TranscriptTail.present(title),
                recordedDirectory: key
            )
        }
        return newest
    }
}
