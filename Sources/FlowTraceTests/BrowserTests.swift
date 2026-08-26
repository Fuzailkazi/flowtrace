import Foundation
import FlowTraceCore

func runBrowserTests() {
    TestKit.suite("Browser tab capture")

    let reader = BrowserTabReader()
    let fs = "\u{1F}", rs = "\u{1E}"

    TestKit.test("parses a window's tabs and marks the active one") {
        let raw = "Acme — Work\(rs)\(rs)"
            + "OAuth 2.0 spec\(fs)https://oauth.net/2/\(fs)0\(rs)"
            + "PKCE explained\(fs)https://example.com/pkce\(fs)1\(rs)"
        let tabs = reader.parse(raw, browser: "Google Chrome")

        expectEqual(tabs.count, 2, "tabs")
        expectEqual(tabs.first?.pageTitle, "OAuth 2.0 spec")
        expectEqual(tabs.first?.url, "https://oauth.net/2/")
        expectEqual(tabs.first?.windowTitle, "Acme — Work")
        expectEqual(tabs.first?.isActive, false)
        expectEqual(tabs.last?.isActive, true)
    }

    // Page titles routinely contain tabs, newlines and separators, which is why
    // the script joins fields with control characters instead.
    TestKit.test("titles containing punctuation survive intact") {
        let raw = "win\(rs)\(rs)"
            + "Weird | title — with, everything: 100%\(fs)https://a.test/x?y=1&z=2\(fs)0\(rs)"
        let tabs = reader.parse(raw, browser: "Safari")
        expectEqual(tabs.count, 1)
        expectEqual(tabs.first?.pageTitle, "Weird | title — with, everything: 100%")
        expectEqual(tabs.first?.url, "https://a.test/x?y=1&z=2")
    }

    TestKit.test("a window with no tabs yields nothing rather than an empty row") {
        expectEqual(reader.parse("", browser: "Google Chrome").count, 0)
        expectEqual(reader.parse("win\(rs)\(rs)", browser: "Google Chrome").count, 0)
    }

    TestKit.test("rows without a usable URL are dropped") {
        let raw = "win\(rs)\(rs)"
            + "Blank\(fs)missing value\(fs)0\(rs)"
            + "Real\(fs)https://ok.test\(fs)0\(rs)"
        let tabs = reader.parse(raw, browser: "Brave Browser")
        expectEqual(tabs.count, 1, "tabs")
        expectEqual(tabs.first?.pageTitle, "Real")
    }

    TestKit.test("a tab with no title falls back to its URL") {
        let raw = "win\(rs)\(rs)\(fs)https://untitled.test/page\(fs)0\(rs)"
        expectEqual(reader.parse(raw, browser: "Dia").first?.pageTitle, "https://untitled.test/page")
    }

    // Safari's scripting dictionary differs from the Chromium family's.
    TestKit.test("Safari and Chromium generate different scripts") {
        let safari = try unwrap(SupportedBrowser.all.first { $0.name == "Safari" })
        let chrome = try unwrap(SupportedBrowser.all.first { $0.name == "Google Chrome" })

        expectContains(reader.script(for: safari, activeOnly: true), "current tab of w")
        expectContains(reader.script(for: safari, activeOnly: false), "name of t")
        expectContains(reader.script(for: chrome, activeOnly: true), "active tab of w")
        expectContains(reader.script(for: chrome, activeOnly: false), "title of t")
    }

    TestKit.test("a captured tab converts to a stored context with its note") {
        let tab = CapturedTab(
            pageTitle: "OAuth 2.0 spec", url: "https://oauth.net/2/",
            browser: "Google Chrome", windowTitle: "Work", isActive: true
        )
        let context = tab.asContext(note: "the canonical reference")
        expectEqual(context.pageTitle, "OAuth 2.0 spec")
        expectEqual(context.note, "the canonical reference")
        expectEqual(context.host, "oauth.net")
    }
}
