import Foundation

// What the endpoint actually does. Kept apart from the socket handling so
// each route reads as plain request-in, response-out.
extension LocalServer {
    // MARK: - Routes

    public func route(_ request: Request) -> Response {
        // /health is unauthenticated so a client can tell "app not running" from
        // "wrong token" — it reveals nothing.
        if request.path == "/health" {
            return Response(status: 200, json: ["ok": true, "app": "flowtrace", "version": "0.1.0"])
        }

        guard let authorization = request.authorization,
              authorization == "Bearer \(token)", !token.isEmpty
        else {
            return .error(401, "Missing or invalid token. Copy it from FlowTrace → Settings.")
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/threads"):
                let threads = try store.allThreads().filter { $0.status != .completed }
                return Response(status: 200, json: [
                    "threads": threads.map {
                        ["id": $0.id, "title": $0.title, "status": $0.status.rawValue]
                    },
                ])

            case ("GET", "/thread-for-url"):
                guard let url = request.query["url"] else {
                    return .error(400, "url is required")
                }
                guard let thread = try store.threadForURL(url) else {
                    return Response(status: 200, json: ["thread": NSNull()])
                }
                return Response(status: 200, json: [
                    "thread": ["id": thread.id, "title": thread.title],
                ])

            case ("POST", "/capture/tabs"):
                return try captureTabs(request)

            case ("POST", "/capture/code"):
                return try captureCode(request)

            default:
                return .error(404, "No such endpoint")
            }
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func captureTabs(_ request: Request) throws -> Response {
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let rawTabs = payload["tabs"] as? [[String: Any]], !rawTabs.isEmpty
        else { return .error(400, "Expected { tabs: [{title, url}], threadId?, note? }") }

        let note = payload["note"] as? String ?? ""
        let browser = payload["browser"] as? String ?? "Browser"

        let contexts = rawTabs.compactMap { raw -> BrowserContext? in
            guard let url = raw["url"] as? String, !url.isEmpty else { return nil }
            return BrowserContext(
                browser: raw["browser"] as? String ?? browser,
                windowTitle: raw["windowTitle"] as? String,
                pageTitle: raw["title"] as? String ?? url,
                url: url,
                note: raw["note"] as? String ?? note
            )
        }
        // Validate before resolving the thread: a request with nothing capturable
        // must not leave an empty thread behind.
        guard !contexts.isEmpty else { return .error(400, "No tabs had a usable URL") }

        let threadId = try resolveThread(payload)
        let saved = try store.attach(tabs: contexts, to: threadId)
        onCapture?()
        return Response(status: 200, json: [
            "captured": saved.count,
            "threadId": threadId as Any? ?? NSNull(),
        ])
    }

    private func captureCode(_ request: Request) throws -> Response {
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let path = payload["path"] as? String
        else { return .error(400, "Expected { path, threadId?, note?, nextStep?, agent? }") }

        guard let state = GitProbe().probe(path) else {
            return .error(422, "\(path) is not inside a git repository")
        }
        let threadId = try resolveThread(payload)

        let context = try store.attach(code: CodeContext(
            agentName: (payload["agent"] as? String).flatMap(AgentName.init(rawValue:)),
            repositoryName: state.repositoryName,
            repositoryPath: state.topLevel,
            branch: state.branch,
            latestCommit: state.headSha,
            note: payload["note"] as? String ?? "",
            nextStep: payload["nextStep"] as? String ?? "",
            dirtyFileCount: state.dirtyFileCount,
            lastCommitAt: state.headDate,
            commitsAhead: state.commitsAhead,
            commitsBehind: state.commitsBehind
        ), to: threadId)

        onCapture?()
        return Response(status: 200, json: [
            "repository": context.repositoryName,
            "branch": context.branch ?? "",
            "threadId": threadId as Any? ?? NSNull(),
        ])
    }

    /// Accepts an existing thread id, or creates one from `newThreadTitle`.
    private func resolveThread(_ payload: [String: Any]) throws -> String? {
        if let id = payload["threadId"] as? String, !id.isEmpty {
            return try store.thread(id: id) != nil ? id : nil
        }
        if let title = (payload["newThreadTitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return try store.create(WorkThread(
                title: title,
                intent: payload["note"] as? String ?? ""
            )).id
        }
        return nil
    }
}
