import Foundation
import FlowTraceCore

func runEditorPlaceTests(fixtures: URL) {
    TestKit.suite("EditorPlace — which window is in front")

    let storage = fixtures.appendingPathComponent("editor/storage.json")

    TestKit.test("reads the focused window, not the list of open ones") {
        let data = try Data(contentsOf: storage)
        expectEqual(EditorPlace.lastActiveFolder(inStorageJSON: data), "/Users/dev/acme")
    }

    TestKit.test("a percent-encoded path is decoded") {
        let json = #"{"windowsState":{"lastActiveWindow":{"folder":"file:///Users/dev/my%20project"}}}"#
        expectEqual(
            EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)),
            "/Users/dev/my project"
        )
    }

    // A remote window's folder is a vscode-remote:// URI. Its path component
    // looks like a local path and is not one — the container's, not yours.
    TestKit.test("a remote window is refused, not mistaken for a local path") {
        for uri in [
            "vscode-remote://ssh-remote+box/home/dev/proj",
            "vscode-remote://dev-container%2B7b22/workspaces/proj",
        ] {
            let json = #"{"windowsState":{"lastActiveWindow":{"folder":"\#(uri)"}}}"#
            expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)), uri)
        }
    }

    // A .code-workspace names several roots in an order that means nothing.
    TestKit.test("a multi-root workspace yields nothing rather than one arbitrary root") {
        let json = #"{"windowsState":{"lastActiveWindow":{"workspaceIdentifier":{"id":"a1","configURIPath":"file:///Users/dev/two.code-workspace"}}}}"#
        expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)))
    }

    TestKit.test("anything malformed yields nothing rather than throwing") {
        for json in [
            #"{}"#,
            #"{"windowsState":{}}"#,
            #"{"windowsState":{"lastActiveWindow":{}}}"#,
            #"{"windowsState":{"lastActiveWindow":{"folder":""}}}"#,
            #"{"windowsState":"not an object"}"#,
            #"{"windowsState":{"lastActiveWindow":{"folder""#,
            "",
        ] {
            expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data(json.utf8)), json)
        }
        expectNil(EditorPlace.lastActiveFolder(inStorageJSON: Data([0xff, 0xfe, 0x00])))
    }

    TestKit.suite("EditorPlace — which editors")

    TestKit.test("the editors we have actually verified are recognised") {
        let code = try unwrap(EditorFamily.matching(bundleIdentifier: "com.microsoft.VSCode"))
        expectEqual(code.supportDirectory, "Code")
        expectEqual(code.displayName, "VS Code")
        let cursor = try unwrap(EditorFamily.matching(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        expectEqual(cursor.supportDirectory, "Cursor")
        expectEqual(cursor.displayName, "Cursor")
    }

    TestKit.test("anything else is not an editor") {
        expectNil(EditorFamily.matching(bundleIdentifier: "com.apple.Safari"))
        expectNil(EditorFamily.matching(bundleIdentifier: nil))
    }

    TestKit.suite("EditorPlace — resolving a place")

    // The temp directory must sit outside any repository: GitProbe walks up,
    // and inside the checkout it would find FlowTrace and the assertions
    // would depend on where the suite was run from.
    func scratch() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flowtrace-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Lays out `<support>/Code/User/globalStorage/storage.json` pointing at
    /// a real directory, so the existence check has something to find.
    func support(folder: URL, in base: URL, modified: Date = Date()) throws -> URL {
        let support = base.appendingPathComponent("Application Support")
        let dir = support.appendingPathComponent("Code/User/globalStorage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("storage.json")
        let json = #"{"windowsState":{"lastActiveWindow":{"folder":"file://\#(folder.path)"}}}"#
        try Data(json.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return support
    }

    TestKit.test("a folder with no repository is still a place") {
        let base = try scratch()
        let project = base.appendingPathComponent("loose-folder")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let place = try unwrap(EditorPlace.place(
            forBundleIdentifier: "com.microsoft.VSCode",
            support: try support(folder: project, in: base)
        ))
        expectEqual(place.name, "loose-folder")
        expectEqual(place.editor, "VS Code")
    }

    // The mtime says when a window last lost focus, not how old the value is.
    // VS Code loads the previous session's state at launch and does not
    // rewrite it until the first blur, so a loose bound returns yesterday's
    // project.
    TestKit.test("a file left by an earlier session is refused") {
        let base = try scratch()
        let project = base.appendingPathComponent("stale")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let support = try support(
            folder: project, in: base, modified: Date().addingTimeInterval(-600)
        )
        expectNil(EditorPlace.place(
            forBundleIdentifier: "com.microsoft.VSCode", support: support, staleness: 120
        ))
    }

    TestKit.test("nothing to resolve is nil, not a guess") {
        let base = try scratch()
        let project = base.appendingPathComponent("here")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let support = try support(folder: project, in: base)
        expectNil(EditorPlace.place(forBundleIdentifier: "com.apple.Safari", support: support))
        expectNil(EditorPlace.place(forBundleIdentifier: nil, support: support))
        // A support tree with no file at all.
        expectNil(EditorPlace.place(
            forBundleIdentifier: "com.microsoft.VSCode",
            support: base.appendingPathComponent("empty")
        ))
    }

    TestKit.test("a folder that no longer exists is not a place") {
        let base = try scratch()
        let gone = base.appendingPathComponent("deleted-since")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let support = try support(folder: gone, in: base)
        try FileManager.default.removeItem(at: gone)
        expectNil(EditorPlace.place(forBundleIdentifier: "com.microsoft.VSCode", support: support))
    }
}
