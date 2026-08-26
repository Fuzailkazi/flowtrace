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
            body: Data = Data(), authorization: String? = nil, origin: String? = nil
        ) {
            self.method = method
            self.path = path
            self.query = query
            self.body = body
            self.authorization = authorization
            self.origin = origin
        }

        public var method: String
        public var path: String
        public var query: [String: String]
        public var body: Data
        public var authorization: String?
        /// Present when the caller is a browser. Only extension origins are
        /// echoed back in the CORS header.
        public var origin: String?
    }

    public struct Response {
        public var status: Int
        public var json: Any?

        public static let ok = Response(status: 200, json: ["ok": true])
        public static func error(_ status: Int, _ message: String) -> Response {
            Response(status: status, json: ["error": message])
        }
    }

    /// Read by the route handlers in LocalServerRoutes.swift.
    let store: Store
    private let queue = DispatchQueue(label: "ai.flowtrace.localserver", attributes: .concurrent)
    private var socketDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// The bearer token every write must present. Read by the route handlers in
    /// LocalServerRoutes.swift; nothing outside this type sets it.
    fileprivate(set) var token: String = ""

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
            let payload = HTTP.serialize(response, origin: request.origin)
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
}
