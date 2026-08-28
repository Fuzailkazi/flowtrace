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

func runBrowserContextTests() {
    TestKit.suite("Browser context in the capture panel")

    let reader = BrowserTabReader()
    let fs = "\u{1F}", rs = "\u{1E}"

    // "You were on this page" and "you were on this page with eleven others" are
    // different facts, and the second is often the more useful one.
    TestKit.test("the whole window is read, so the other tabs can be counted") {
        let raw = "Work\(rs)\(rs)"
            + "Pencil — Untitled\(fs)https://pencil.com\(fs)1\(rs)"
            + "logo design tools\(fs)https://google.com/search?q=logo\(fs)0\(rs)"
            + "dribbble\(fs)https://dribbble.com\(fs)0\(rs)"
        let tabs = reader.parse(raw, browser: "Brave Browser")

        expectEqual(tabs.count, 3, "tabs in the window")
        expectEqual(tabs.first(where: \.isActive)?.pageTitle, "Pencil — Untitled")
    }

    // Automation is granted per pair of apps, so being allowed to ask Chrome says
    // nothing about Brave. This used to fall through to a bare app name, making a
    // browser FlowTrace had never been permitted look identical to one with
    // nothing open.
    TestKit.test("a refusal is a distinct outcome, not an empty result") {
        let denied = BrowserReadError.permissionDenied("Brave Browser")
        expectContains(denied.errorDescription, "Brave Browser")
        expectContains(denied.recoverySuggestion, "Automation")

        let notRunning = BrowserReadError.notRunning("Safari")
        expectNotContains(notRunning.recoverySuggestion, "Automation")
    }

    TestKit.test("every browser we claim to support has a real bundle identifier") {
        for browser in SupportedBrowser.all {
            expect(browser.bundleIdentifier.contains("."), "\(browser.name)")
            expect(!browser.name.isEmpty)
        }
        // The ones on this machine, by identifier rather than by name.
        let identifiers = Set(SupportedBrowser.all.map(\.bundleIdentifier))
        for expected in ["com.brave.Browser", "com.google.Chrome",
                         "company.thebrowser.dia", "com.apple.Safari"] {
            expect(identifiers.contains(expected), "missing \(expected)")
        }
    }
}

func runTabNoteTests() {
    TestKit.suite("Notes on pages")

    // The point of asking why you opened something is being able to find out
    // later, when you no longer have it open. A note keyed on a tab or a window
    // would die with them; keyed on the address it survives.
    TestKit.test("a page's reason outlives the tab") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.noteTab(
            url: "https://pencil.com", title: "Pencil — Untitled",
            browser: "Brave Browser", note: "making a logo for flowtrace"
        )
        // The tab is gone; the reason is not.
        expectEqual(try store.noteForTab(url: "https://pencil.com"),
                    "making a logo for flowtrace")
    }

    TestKit.test("writing about the same page twice updates rather than duplicates") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.noteTab(url: "https://x.test", title: "X", browser: "Dia", note: "first")
        _ = try store.noteTab(url: "https://x.test", title: "X", browser: "Dia", note: "second")

        expectEqual(try store.notedTabs().count, 1, "one entry")
        expectEqual(try store.noteForTab(url: "https://x.test"), "second")
    }

    TestKit.test("a page you never wrote about has no reason") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        expectNil(try store.noteForTab(url: "https://never-seen.test"))
    }

    TestKit.test("noted pages appear on the day you wrote them") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.noteTab(
            url: "https://oauth.net/2/", title: "OAuth 2.0 spec",
            browser: "Chrome", note: "the spec I keep re-finding"
        )
        let today = try store.activity(on: Date(), minimumSeconds: 0)
        expect(today.contains { $0.url == "https://oauth.net/2/" }, "on the timeline")
    }

    TestKit.test("clearing a page's note removes the reason but keeps the record") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        _ = try store.noteTab(url: "https://y.test", title: "Y", browser: "Dia", note: "why")
        _ = try store.noteTab(url: "https://y.test", title: "Y", browser: "Dia", note: "  ")
        expectNil(try store.noteForTab(url: "https://y.test"), "reason cleared")
    }
}
