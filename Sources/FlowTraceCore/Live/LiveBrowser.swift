import Foundation

/// A browser you have open, and what is in it.
public struct LiveBrowser: Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var tabs: [CapturedTab]
    /// Set when FlowTrace hasn't been allowed to ask this browser anything.
    public var needsPermission: Bool

    public init(name: String, tabs: [CapturedTab] = [], needsPermission: Bool = false) {
        self.name = name
        self.tabs = tabs
        self.needsPermission = needsPermission
    }

    public var activeTab: CapturedTab? {
        tabs.first(where: \.isActive) ?? tabs.first
    }

    public var otherTabCount: Int { max(0, tabs.count - 1) }
}

extension LiveStateReader {
    /// Reads every open tab in every running browser.
    ///
    /// Kept off the main `read()` path deliberately: this costs roughly half a
    /// second across three browsers, which is fine occasionally and far too much
    /// at the refresh rate the agent and server lists run at.
    public func readBrowsers() -> [LiveBrowser] {
        let reader = BrowserTabReader()
        return reader.availableBrowsers().map { browser in
            do {
                let tabs = try reader.tabsInFrontWindow(of: browser)
                return LiveBrowser(name: browser.name, tabs: tabs)
            } catch let error as BrowserReadError {
                if case .permissionDenied = error {
                    return LiveBrowser(name: browser.name, needsPermission: true)
                }
                return LiveBrowser(name: browser.name)
            } catch {
                return LiveBrowser(name: browser.name)
            }
        }
        .filter { !$0.tabs.isEmpty || $0.needsPermission }
    }
}

extension Store {
    /// Writes a reason against a page.
    ///
    /// Keyed on the URL rather than on a tab or a window, so it survives the tab
    /// being closed: the whole point is finding out next week why you opened
    /// something you no longer have open.
    @discardableResult
    public func noteTab(
        url: String, title: String, browser: String, note: String
    ) throws -> ActivityEvent {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = try existingTabEvent(url: url) {
            return try annotate(activityId: existing.id, note: trimmed) ?? existing
        }

        let now = Date()
        var event = ActivityEvent(
            kind: .browserTab,
            startedAt: now,
            endedAt: now,
            appName: browser,
            target: title,
            url: url,
            note: trimmed.isEmpty ? nil : trimmed,
            noteAt: trimmed.isEmpty ? nil : now
        )
        try database.writer.write { db in try event.insert(db) }
        return event
    }

    /// The most recent note against a page, whether or not it is still open.
    public func noteForTab(url: String) throws -> String? {
        try existingTabEvent(url: url)?.note
    }

    /// Every page you've written about, newest first.
    public func notedTabs(limit: Int = 100) throws -> [ActivityEvent] {
        try database.writer.read { db in
            try ActivityEvent
                .filter(sql: "kind = ? AND note IS NOT NULL",
                        arguments: [ActivityKind.browserTab.rawValue])
                .order(ActivityEvent.Columns.startedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private func existingTabEvent(url: String) throws -> ActivityEvent? {
        try database.writer.read { db in
            try ActivityEvent
                .filter(sql: "url = ? AND note IS NOT NULL", arguments: [url])
                .order(ActivityEvent.Columns.startedAt.desc)
                .fetchOne(db)
        }
    }
}
