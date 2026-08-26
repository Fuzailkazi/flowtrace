import Foundation
import GRDB

/// A captured browser tab. FlowTrace stores the title and URL only — never page
/// contents, cookies, form values or credentials.
public struct BrowserContext: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var workThreadId: String?
    public var browser: String
    public var windowTitle: String?
    public var pageTitle: String
    public var url: String
    /// "Why did I open this?" — supplied by the user at capture time.
    public var note: String
    public var capturedAt: Date

    public init(
        id: String = UUID().uuidString,
        workThreadId: String? = nil,
        browser: String,
        windowTitle: String? = nil,
        pageTitle: String,
        url: String,
        note: String = "",
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.workThreadId = workThreadId
        self.browser = browser
        self.windowTitle = windowTitle
        self.pageTitle = pageTitle
        self.url = url
        self.note = note
        self.capturedAt = capturedAt
    }

    /// Host only, for compact display in lists.
    public var host: String {
        URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

extension BrowserContext: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "browserContext"

    public enum Columns {
        public static let id = Column("id")
        public static let workThreadId = Column("workThreadId")
        public static let url = Column("url")
        public static let capturedAt = Column("capturedAt")
    }
}
