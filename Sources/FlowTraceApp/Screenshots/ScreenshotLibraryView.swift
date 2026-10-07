import AppKit
import FlowTraceCore
import SwiftUI

struct ScreenshotLibraryView: View {
    @Bindable var model: AppModel
    @State private var importer = ScreenshotImportController()
    @State private var query = ""
    @State private var rows: [ScreenshotMetadata] = []
    @State private var error: String?
    @State private var loading = false
    @State private var hasMore = true
    @State private var generation = 0
    private let pageSize = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Screenshots").font(.largeTitle.bold())
                Text("Save an image deliberately, then find it by visible text or your description. Stored locally without encryption.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Import image", systemImage: "square.and.arrow.down") { importer.importFile(into: model) }
                    Button("Paste screenshot", systemImage: "doc.on.clipboard") { importer.paste(into: model) }
                }
                .disabled(importer.isImporting)
                if importer.isImporting { ProgressView("Processing image and recognizing text…") }
                if let message = importer.error { Text(message).foregroundStyle(.red) }
                if let message = importer.success { Text(message).foregroundStyle(.secondary) }
                TextField("Search screenshots", text: $query)
                    .textFieldStyle(.roundedBorder)
                if let error {
                    Text("Could not load screenshots: \(error)").foregroundStyle(.red)
                    Button("Retry") { load(reset: rows.isEmpty) }
                }
                if rows.isEmpty && !loading && error == nil {
                    ContentUnavailableView(query.isEmpty ? "No screenshots yet" : "No matches", systemImage: "photo.stack", description: Text(query.isEmpty ? "Import an image or paste one from the clipboard." : "Try different words from the image or its description."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 12)], spacing: 12) {
                    ForEach(rows) { row in
                        Button {
                            model.route = .screenshot(row.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                if let image = NSImage(data: row.thumbnailData) {
                                    Image(nsImage: image).resizable().scaledToFit()
                                        .frame(maxWidth: .infinity).frame(height: 130)
                                        .background(.quaternary.opacity(0.25))
                                }
                                Text(row.description.isEmpty ? "Screenshot" : row.description)
                                    .lineLimit(2).font(.headline)
                                Text(row.importedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                if row.ocrStatus == .failed {
                                    Label("Text recognition failed", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                if hasMore && !loading && !rows.isEmpty {
                    Button("Load more") { load(reset: false) }
                }
                if loading { ProgressView() }
            }
            .padding(24)
        }
        .task { load(reset: true) }
        .onChange(of: query) { _, _ in load(reset: true) }
        .onChange(of: model.activityRevision) { _, _ in load(reset: true) }
    }

    private func load(reset: Bool) {
        if reset {
            generation += 1
            rows = []
            hasMore = true
        }
        guard hasMore else { return }
        let current = generation
        let offset = rows.count
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = model.store
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            let result = Result {
                search.isEmpty ? try store.screenshots(limit: pageSize, offset: offset)
                    : try store.searchScreenshots(query: search, limit: pageSize, offset: offset)
            }
            await MainActor.run {
                guard current == generation else { return }
                loading = false
                switch result {
                case .success(let page):
                    rows.append(contentsOf: page)
                    hasMore = page.count == pageSize
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
}
