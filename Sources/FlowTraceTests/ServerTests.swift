import Foundation
import FlowTraceCore

/// Route-level tests. They exercise the real request handling without binding a
/// socket, so they're deterministic and don't need a free port.
func runServerTests() {
    TestKit.suite("Local endpoint — HTTP parsing")

    TestKit.test("parses method, path, query and body") {
        let raw = "POST /capture/tabs?dry=1 HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Authorization: Bearer abc123\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: 12\r\n\r\n"
            + #"{"tabs":[""}"#
        let request = try unwrap(HTTP.parse(Data(raw.utf8)))
        expectEqual(request.method, "POST")
        expectEqual(request.path, "/capture/tabs")
        expectEqual(request.query["dry"], "1")
        expectEqual(request.authorization, "Bearer abc123")
        expectEqual(request.body.count, 12, "body length")
    }

    // A request arrives in chunks; parsing must wait rather than act on half of it.
    TestKit.test("returns nil until the body has fully arrived") {
        let head = "POST /capture/tabs HTTP/1.1\r\nContent-Length: 20\r\n\r\n"
        expectNil(HTTP.parse(Data(head.utf8)), "headers only")
        expectNil(HTTP.parse(Data((head + "12345").utf8)), "partial body")
        expectNotNil(HTTP.parse(Data((head + "12345678901234567890").utf8)), "complete body")
    }

    TestKit.test("percent-encoded query values are decoded") {
        let raw = "GET /thread-for-url?url=https%3A%2F%2Foauth.net%2F2%2F HTTP/1.1\r\n\r\n"
        let request = try unwrap(HTTP.parse(Data(raw.utf8)))
        expectEqual(request.query["url"], "https://oauth.net/2/")
    }

    TestKit.suite("Local endpoint — routes")

    // A literal token, so the suite never touches the real keychain.
    func harness() throws -> (LocalServer, Store, String) {
        let store = try Store(database: FlowTraceDatabase.inMemory())
        let server = LocalServer(store: store)
        let token = "test-token"
        server.primeTokenForTesting(token)
        return (server, store, token)
    }

    func request(
        _ method: String, _ path: String,
        token: String?, body: [String: Any]? = nil, query: [String: String] = [:]
    ) -> LocalServer.Request {
        LocalServer.Request(
            method: method, path: path, query: query,
            body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data(),
            authorization: token.map { "Bearer \($0)" }
        )
    }

    TestKit.test("health needs no token and leaks nothing") {
        let (server, _, _) = try harness()
        let response = server.route(request("GET", "/health", token: nil))
        expectEqual(response.status, 200)
        let json = try unwrap(response.json as? [String: Any])
        expectEqual(json["app"] as? String, "flowtrace")
    }

    TestKit.test("every other route rejects a missing or wrong token") {
        let (server, _, _) = try harness()
        expectEqual(server.route(request("GET", "/threads", token: nil)).status, 401, "no token")
        expectEqual(server.route(request("GET", "/threads", token: "wrong")).status, 401, "wrong token")
        expectEqual(
            server.route(request("POST", "/capture/tabs", token: "wrong", body: [:])).status,
            401, "wrong token on write"
        )
    }

    TestKit.test("captures tabs into a new thread") {
        let (server, store, token) = try harness()
        let response = server.route(request("POST", "/capture/tabs", token: token, body: [
            "newThreadTitle": "OAuth research",
            "note": "the spec I keep re-finding",
            "tabs": [
                ["title": "OAuth 2.0 spec", "url": "https://oauth.net/2/"],
                ["title": "PKCE explained", "url": "https://example.com/pkce"],
            ],
        ]))
        expectEqual(response.status, 200)
        expectEqual((response.json as? [String: Any])?["captured"] as? Int, 2, "captured")

        let thread = try unwrap(try store.allThreads().first)
        expectEqual(thread.title, "OAuth research")
        expectEqual(try store.tabs(threadId: thread.id).count, 2, "linked tabs")
    }

    // Internal pages and anything without a URL must not become empty records.
    TestKit.test("tabs without a usable URL are refused, not stored empty") {
        let (server, store, token) = try harness()
        let response = server.route(request("POST", "/capture/tabs", token: token, body: [
            "newThreadTitle": "Nothing", "tabs": [["title": "New Tab"]],
        ]))
        expectEqual(response.status, 400)
        expectEqual(try store.allThreads().count, 0, "no thread created")
    }

    TestKit.test("the badge lookup answers for known and unknown urls") {
        let (server, _, token) = try harness()
        _ = server.route(request("POST", "/capture/tabs", token: token, body: [
            "newThreadTitle": "Pricing", "tabs": [["title": "Stripe", "url": "https://stripe.com/pricing"]],
        ]))

        let known = server.route(request(
            "GET", "/thread-for-url", token: token, query: ["url": "https://stripe.com/pricing"]
        ))
        let thread = try unwrap((known.json as? [String: Any])?["thread"] as? [String: Any])
        expectEqual(thread["title"] as? String, "Pricing")

        let unknown = server.route(request(
            "GET", "/thread-for-url", token: token, query: ["url": "https://nowhere.test"]
        ))
        expect((unknown.json as? [String: Any])?["thread"] is NSNull, "unknown url returns null")
    }

    TestKit.test("attaching a path that isn't a repository is refused") {
        let (server, _, token) = try harness()
        let response = server.route(request("POST", "/capture/code", token: token, body: [
            "path": "/definitely/not/a/repo",
        ]))
        expectEqual(response.status, 422)
    }

    TestKit.test("completed threads aren't offered as capture targets") {
        let (server, store, token) = try harness()
        let open = try store.create(WorkThread(title: "Open work"))
        let done = try store.create(WorkThread(title: "Finished work"))
        _ = try store.setStatus(.completed, threadId: done.id)

        let response = server.route(request("GET", "/threads", token: token))
        let threads = try unwrap((response.json as? [String: Any])?["threads"] as? [[String: Any]])
        expectEqual(threads.count, 1, "offered threads")
        expectEqual(threads.first?["id"] as? String, open.id)
    }

    TestKit.test("unknown routes 404") {
        let (server, _, token) = try harness()
        expectEqual(server.route(request("GET", "/nope", token: token)).status, 404)
    }
}

/// A wildcard CORS header on the unauthenticated /health route let any web page
/// the user visited silently detect that FlowTrace was installed, and which
/// version. Only browser extensions get a CORS header now.
func runCORSTests() {
    TestKit.suite("Local endpoint — cross-origin access")

    func serialized(origin: String?) -> String {
        let request = LocalServer.Request(
            method: "GET", path: "/health", origin: origin
        )
        _ = request
        return String(decoding: HTTP.serialize(.ok, origin: origin), as: UTF8.self)
    }

    TestKit.test("an ordinary web page gets no CORS header, so it can't fingerprint us") {
        let response = serialized(origin: "https://evil.example")
        expectNotContains(response, "Access-Control-Allow-Origin")
    }

    TestKit.test("a browser extension is allowed, and echoed exactly") {
        let response = serialized(origin: "chrome-extension://abcdef")
        expectContains(response, "Access-Control-Allow-Origin: chrome-extension://abcdef")
        expectContains(response, "Vary: Origin")
    }

    TestKit.test("no wildcard is ever emitted") {
        for origin in [nil, "https://evil.example", "chrome-extension://x", "null"] {
            expectNotContains(serialized(origin: origin), "Allow-Origin: *")
        }
    }

    TestKit.test("Origin is parsed off the request") {
        let raw = "GET /health HTTP/1.1\r\nOrigin: chrome-extension://xyz\r\n\r\n"
        let parsed = try unwrap(HTTP.parse(Data(raw.utf8)))
        expectEqual(parsed.origin, "chrome-extension://xyz")
    }
}
