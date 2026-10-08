import AppKit
import FlowTraceCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScreenshotImportController {
    private enum ImportError: LocalizedError {
        case emptyClipboard

        var errorDescription: String? {
            "The clipboard has no image. Copy an image, then try Paste screenshot again."
        }
    }

    var isImporting = false
    var error: String?
    var success: String?

    func importFile(into model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(into: model) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value <= 25_000_000 else {
                throw ScreenshotImageError.inputTooLarge
            }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }

    func paste(into model: AppModel) {
        guard !isImporting else { return }
        // Capture the clipboard selection at click time. Reading it in the
        // detached import job could save a different image if the user copies
        // something else before that job starts.
        guard let data = NSPasteboard.general.data(forType: .png)
            ?? NSPasteboard.general.data(forType: .tiff)
            ?? NSPasteboard.general.data(forType: .init("public.jpeg"))
        else {
            success = nil
            error = ImportError.emptyClipboard.localizedDescription
            return
        }
        importImage(into: model) { data }
    }

    private func importImage(into model: AppModel, read: @escaping @Sendable () throws -> Data) {
        guard !isImporting else { return }
        error = nil
        success = nil
        isImporting = true
        let store = model.store
        let started = model.startTrackedDataJob(priority: .userInitiated) {
            let result = Result {
                let input = try read()
                guard input.count <= 25_000_000 else { throw ScreenshotImageError.inputTooLarge }
                let processed = try ScreenshotImageProcessor.process(input)
                return try store.createScreenshot(imageData: processed.imageData,
                    thumbnailData: processed.thumbnailData, ocrText: processed.ocrText,
                    ocrStatus: processed.ocrStatus)
            }
            await MainActor.run {
                self.isImporting = false
                switch result {
                case .success(let screenshot):
                    self.success = screenshot.ocrStatus == .failed
                        ? "Image saved. Text recognition failed; you can add a description or retry in the detail view."
                        : "Screenshot saved on this Mac."
                    model.activityRevision += 1
                case .failure(let failure):
                    self.error = "Could not save image: \(failure.localizedDescription)"
                }
            }
        }
        if !started {
            isImporting = false
            error = "Cannot import while FlowTrace is deleting stored data. Try again when deletion finishes."
        }
    }
}
