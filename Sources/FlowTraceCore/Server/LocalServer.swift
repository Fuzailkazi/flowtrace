import Foundation

/// A tiny HTTP endpoint the browser extension and the CLI talk to.
///
/// It binds to 127.0.0.1 only and every request must carry the bearer token from
/// the keychain, so nothing outside this machine — and nothing on it that hasn't
/// been shown the token — can write into the database.
///
/// Built on Network.framework rather than a server framework: five routes with
/// no streaming, no TLS and no routing table doesn't justify a dependency tree.
public final class LocalServer {
    public struct Request {
        public init(
            method: String, path: String, query: [String: String] = [:],
            body: Data = Data(), authorization: String? = nil
        ) {
            self.method = method
            self.path = path
            self.query = query
            self.body = body
            self.authorization = authorization
        }

        public var method: String
        public var path: String
        public var query: [String: String]
        public var body: Data
        public var authorization: String?
    }

    public struct Response {
        public var status: Int
        public var json: Any?

        public static let ok = Response(status: 200, json: ["ok": true])
        public static func error(_ status: Int, _ message: String) -> Response {
            Response(status: status, json: ["error": message])
        }
    }

    private let store: Store
    private let queue = DispatchQueue(label: "ai.flowtrace.localserver", attributes: .concurrent)
    private var socketDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var token: String = ""

    public private(set) var port: UInt16?
    /// Called after a successful capture so the UI can refresh.
    public var onCapture: (() -> Void)?
    /// Reports why the endpoint stopped, so a failure is visible rather than silent.
    public var onFailure: ((String) -> Void)?

    public init(store: Store) {
        self.store = store
    }

    // MARK: - Lifecycle

    /// Binds a listening socket to 127.0.0.1.
    ///
    /// A plain BSD socket rather than Network.framework: binding explicitly to
    /// `INADDR_LOOPBACK` is a hard guarantee that nothing off this machine can
    /// reach the endpoint, and it needs no networking daemon to be available.
    public func start(preferredPort: UInt16 = 8787) throws {
        token = try LocalCredentials.token()

        // Take the well-known port so the extension usually needs no setup; if
        // something else already holds it, take any free one and publish that.
        do {
            try bind(to: preferredPort)
        } catch {
            try bind(to: 0)
        }
    }

    private func bind(to requestedPort: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalServerError.couldNotBind("socket() failed (errno \(errno))")
        }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(descriptor)
            throw LocalServerError.couldNotBind(
                code == EADDRINUSE
                    ? "port \(requestedPort) is already in use"
                    : "bind() failed (errno \(code))"
            )
        }

        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw LocalServerError.couldNotBind("listen() failed (errno \(code))")
        }

        // Read back the port the kernel actually assigned when we asked for 0.
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didResolve = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length) == 0
            }
        }
        let resolved = didResolve ? UInt16(bigEndian: bound.sin_port) : requestedPort

        socketDescriptor = descriptor
        port = resolved
        LocalCredentials.publish(port: resolved)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        socketDescriptor = -1
        port = nil
        LocalCredentials.clearPublishedPort()
    }

    deinit {
        acceptSource?.cancel()
    }

    // MARK: - Connection handling

    private func acceptOne() {
        var address = sockaddr()
        var length = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(socketDescriptor, &address, &length)
        guard client >= 0 else { return }

        queue.async { [weak self] in
            defer { close(client) }
            guard let self, let request = Self.readRequest(from: client) else { return }
            let response = self.route(request)
            let payload = HTTP.serialize(response)
            payload.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var sent = 0
                while sent < buffer.count {
                    let written = send(client, base.advanced(by: sent), buffer.count - sent, 0)
                    if written <= 0 { return }
                    sent += written
                }
            }
        }
    }

    /// Reads until the request is complete, bounded in both size and time so a
    /// stalled client can't hold a worker.
    private static func readRequest(from descriptor: Int32) -> Request? {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while buffer.count < (1 << 20) {
            let read = recv(descriptor, &chunk, chunk.count, 0)
            if read <= 0 { break }
            buffer.append(contentsOf: chunk[0..<read])
            if let request = HTTP.parse(buffer) { return request }
        }
        return HTTP.parse(buffer)
    }

    /// Sets the expected token without starting a listener, so route handling
    /// can be tested without binding a port.
    public func primeTokenForTesting(_ token: String) {
        self.token = token
    }

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

// MARK: - Minimal HTTP/1.1

public enum HTTP {
    /// Returns nil while the request is still incomplete, so the caller keeps reading.
    public static func parse(_ data: Data) -> LocalServer.Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerText = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let expectedLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.count - bodyStart
        guard available >= expectedLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + expectedLength))

        var path = target
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            let rawQuery = String(target[target.index(after: questionMark)...])
            for pair in rawQuery.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                query[String(kv[0]).removingPercentEncoding ?? String(kv[0])] =
                    String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                    ?? String(kv[1])
            }
        }

        return LocalServer.Request(
            method: method, path: path, query: query, body: body,
            authorization: headers["authorization"]
        )
    }

    public static func serialize(_ response: LocalServer.Response) -> Data {
        let body: Data
        if let json = response.json,
           let encoded = try? JSONSerialization.data(withJSONObject: json) {
            body = encoded
        } else {
            body = Data("{}".utf8)
        }

        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // The extension is a different origin; nothing here is a browser-credentialed
        // endpoint, and the bearer token is what actually gates access.
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: authorization, content-type\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 422: "Unprocessable Entity"
        default: "Internal Server Error"
        }
    }
}
