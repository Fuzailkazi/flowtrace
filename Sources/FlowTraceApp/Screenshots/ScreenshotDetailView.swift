import AppKit
import FlowTraceCore
import SwiftUI

struct ScreenshotDetailView: View {
    @Bindable var model: AppModel
    let id: String
    @State private var screenshot: ScreenshotMemory?
    @State private var description = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var loadGeneration = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Back to Screenshots", systemImage: "chevron.left") { model.route = .screenshots }
                if let screenshot {
                    Text(screenshot.importedAt.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)
                    if let image = NSImage(data: screenshot.imageData) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("The saved image could not be displayed.").foregroundStyle(.red)
                    }
                    TextField("Add a description", text: $description)
                        .textFieldStyle(.roundedBorder)
                    Button("Save description") { saveDescription() }.disabled(busy || description == screenshot.description)
                    if screenshot.ocrStatus == .failed {
                        Label("Text recognition failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Retry text recognition") { retryOCR() }.disabled(busy)
                    } else if screenshot.ocrStatus == .pending {
                        Text("Text recognition pending").foregroundStyle(.secondary)
                        Button("Retry text recognition") { retryOCR() }.disabled(busy)
                    } else {
                        Text("Recognized text").font(.headline)
                        Text(screenshot.ocrText.isEmpty ? "No text found in this image." : screenshot.ocrText)
                            .textSelection(.enabled)
                    }
                    Button("Delete screenshot", role: .destructive) { confirmingDelete = true }
                        .disabled(busy)
                } else if error == nil {
                    ProgressView("Loading screenshot…")
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(24)
        }
        .confirmationDialog("Delete this screenshot?", isPresented: $confirmingDelete) {
            Button("Delete screenshot", role: .destructive) { delete() }
        } message: { Text("The saved image and recognized text will be removed from this Mac.") }
        .task(id: id) { load() }
    }

    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let requestedID = id
        screenshot = nil
        description = ""
        error = nil
        confirmingDelete = false
        let store = model.store
        Task.detached(priority: .userInitiated) {
            let result = Result { try store.screenshot(id: requestedID) }
            await MainActor.run {
                guard generation == loadGeneration, requestedID == id else { return }
                switch result {
                case .success(let value):
                    screenshot = value
                    description = value?.description ?? ""
                    if value == nil { error = "This screenshot is no longer available." }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func saveDescription() {
        guard screenshot?.id == id else { return }
        let store = model.store
        let value = description
        busy = true
        error = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try store.updateScreenshotDescription(id: id, description: value) }
            await MainActor.run {
                guard model.route == .screenshot(id) else { return }
                busy = false
                switch result {
                case .success: model.activityRevision += 1; load()
                case .failure(let failure): error = "Could not save description: \(failure.localizedDescription)"
                }
            }
        }
    }

    private func retryOCR() {
        guard let screenshot, screenshot.id == id else { return }
        let store = model.store
        let data = screenshot.imageData
        busy = true
        error = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try ScreenshotImageProcessor.recognizeText(in: data) }
            let status: ScreenshotOCRStatus = result.isSuccess ? .succeeded : .failed
            let text = (try? result.get()) ?? ""
            let saved = Result { try store.updateScreenshotOCR(id: id, text: text, status: status) }
            await MainActor.run {
                guard model.route == .screenshot(id) else { return }
                busy = false
                if case .failure(let failure) = saved { error = "Could not save recognition result: \(failure.localizedDescription)" }
                else if case .failure(let failure) = result { error = "Text recognition failed: \(failure.localizedDescription)" }
                model.activityRevision += 1
                load()
            }
        }
    }

    private func delete() {
        guard screenshot?.id == id else { return }
        let store = model.store
        busy = true
        error = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try store.deleteScreenshot(id: id) }
            await MainActor.run {
                guard model.route == .screenshot(id) else { return }
                busy = false
                switch result {
                case .success: model.activityRevision += 1; model.route = .screenshots
                case .failure(let failure): error = "Could not delete screenshot: \(failure.localizedDescription)"
                }
            }
        }
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
