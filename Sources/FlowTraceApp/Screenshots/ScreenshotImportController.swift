import AppKit
import FlowTraceCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ScreenshotImportController {
    var isImporting = false
    var error: String?
    var success: String?

    func importFile(into model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(into: model) { try Data(contentsOf: url, options: .mappedIfSafe) }
    }

    func paste(into model: AppModel) {
        guard let data = NSPasteboard.general.data(forType: .png)
            ?? NSPasteboard.general.data(forType: .tiff)
            ?? NSPasteboard.general.data(forType: .init("public.jpeg"))
        else {
            error = "The clipboard has no image. Copy an image, then try Paste screenshot again."
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
        Task.detached(priority: .userInitiated) {
            let result = Result {
                let processed = try ScreenshotImageProcessor.process(read())
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
    }
}
