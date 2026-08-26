import Foundation

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
