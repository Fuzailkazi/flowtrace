import Foundation
import FlowTraceCore
import AppKit
import ImageIO
import UniformTypeIdentifiers

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
        expectEqual(try store.searchScreenshots(query: "Page", limit: Int.max, offset: Int.max).count, 0)
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

    TestKit.test("processor rejects unreadable, oversized, and excessive pixel images") {
        do {
            _ = try ScreenshotImageProcessor.process(Data([1, 2, 3]))
            expect(false, "invalid image must fail")
        } catch is ScreenshotImageError { }
        do {
            _ = try ScreenshotImageProcessor.process(Data(repeating: 0, count: 25_000_001))
            expect(false, "oversized input must fail")
        } catch ScreenshotImageError.inputTooLarge { }
        let large = screenshotTestImage(width: 4097, height: 4097)
        do {
            _ = try ScreenshotImageProcessor.process(large)
            expect(false, "excessive source pixels must fail")
        } catch ScreenshotImageError.tooManyPixels { }
    }

    TestKit.test("processor bounds JPEG outputs and strips source metadata") {
        let source = screenshotTestImage(width: 800, height: 500, gps: true)
        let processed = try ScreenshotImageProcessor.process(source)
        expect(processed.imageData.count <= 10_000_000)
        expect(processed.thumbnailData.count <= 128_000)
        let imageSource = try unwrap(CGImageSourceCreateWithData(processed.imageData as CFData, nil))
        let image = try unwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        expect(image.width <= 4096 && image.height <= 4096)
        let properties = try unwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
        expectNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        expectNil(exif[kCGImagePropertyExifUserComment])
        let thumbSource = try unwrap(CGImageSourceCreateWithData(processed.thumbnailData as CFData, nil))
        expectNotNil(CGImageSourceCreateImageAtIndex(thumbSource, 0, nil))
    }

    TestKit.test("recognized screenshot text is searchable") {
        let processed = try ScreenshotImageProcessor.process(screenshotTestImage(width: 800, height: 300, text: "FLOWTRACE 7392"))
        expectEqual(processed.ocrStatus, .succeeded)
        expectContains(processed.ocrText.uppercased(), "FLOWTRACE")
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let saved = try store.createScreenshot(imageData: processed.imageData,
                                               thumbnailData: processed.thumbnailData,
                                               ocrText: processed.ocrText, ocrStatus: processed.ocrStatus)
        expectEqual(try store.searchScreenshots(query: "FLOWTRACE").first?.id, saved.id)
    }
}

private func screenshotTestImage(width: Int, height: Int, text: String? = nil, gps: Bool = false) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                  bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    if let text {
        (text as NSString).draw(at: NSPoint(x: 50, y: height / 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black
        ])
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = gps ? [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.7],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private source comment"]
    ] : [:]
    CGImageDestinationAddImage(destination, bitmap.cgImage!, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
