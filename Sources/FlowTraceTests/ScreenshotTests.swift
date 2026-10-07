import Foundation
import FlowTraceCore

func runScreenshotTests() {
    TestKit.suite("Screenshots")

    TestKit.test("save, reopen, search, edit, retry, and delete") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flowtrace-screenshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let image = Data(repeating: 0x41, count: 200_000)
        let thumbnail = Data(repeating: 0x42, count: 1_000)
        let store = try Store(url: url)
        let saved = try store.createScreenshot(imageData: image, thumbnailData: thumbnail,
                                               description: "Planning board", ocrText: "launch timeline",
                                               ocrStatus: .succeeded)
        expectEqual(try store.screenshotCount(), 1)
        expectEqual(try store.screenshots().first?.thumbnailData, thumbnail)
        expectEqual(try store.searchScreenshots(query: "timeline").first?.id, saved.id)
        expectEqual(try store.search("timeline").first?.kind, .screenshot)

        let reopened = try Store(url: url)
        expectEqual(try reopened.screenshot(id: saved.id)?.imageData, image)
        try reopened.updateScreenshotDescription(id: saved.id, description: "Release calendar")
        expectEqual(try reopened.searchScreenshots(query: "calendar").first?.id, saved.id)
        expectEqual(try reopened.searchScreenshots(query: "planning").count, 0)
        try reopened.updateScreenshotOCR(id: saved.id, text: "revised milestone", status: .succeeded)
        expectEqual(try reopened.searchScreenshots(query: "milestone").first?.id, saved.id)
        expectEqual(try reopened.searchScreenshots(query: "timeline").count, 0)
        try reopened.deleteScreenshot(id: saved.id)
        expectEqual(try reopened.screenshotCount(), 0)
        expectEqual(try reopened.search("milestone").count, 0)
    }

    TestKit.test("metadata pages have thumbnails and no full image field") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let image = Data(repeating: 0x41, count: 500_000)
        for number in 0..<3 {
            _ = try store.createScreenshot(imageData: image, thumbnailData: Data([UInt8(number)]),
                                           description: "Page \(number)")
        }
        expectEqual(try store.screenshots(limit: 2).count, 2)
        expectEqual(try store.screenshots(limit: 2, offset: 2).count, 1)
        expectEqual(Mirror(reflecting: try unwrap(store.screenshots().first)).children.map(\.label).contains("imageData"), false)
        expectEqual(try store.screenshotCount(), 3)
    }

    TestKit.test("failed OCR can be retried and image limits are enforced") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let saved = try store.createScreenshot(imageData: Data([1]), thumbnailData: Data([2]),
                                               description: "Error dialog", ocrStatus: .failed)
        expectEqual(try store.screenshot(id: saved.id)?.ocrStatus, .failed)
        try store.updateScreenshotOCR(id: saved.id, text: "network unavailable", status: .succeeded)
        expectEqual(try store.searchScreenshots(query: "network").first?.id, saved.id)
        do {
            _ = try store.createScreenshot(imageData: Data(), thumbnailData: Data([1]))
            expect(false, "empty image must fail")
        } catch is ScreenshotStoreError { }
        do {
            _ = try store.createScreenshot(imageData: Data(repeating: 1, count: 10_000_001), thumbnailData: Data([1]))
            expect(false, "oversized image must fail")
        } catch is ScreenshotStoreError { }
    }

    TestKit.test("delete all data removes screenshot bytes and index entries") {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let saved = try store.createScreenshot(imageData: Data([1, 2]), thumbnailData: Data([3]),
                                               description: "Disposable drawing")
        try store.deleteAllData()
        expectEqual(try store.screenshotCount(), 0)
        expectNil(try store.screenshot(id: saved.id))
        expectEqual(try store.search("Disposable").count, 0)
    }
}
