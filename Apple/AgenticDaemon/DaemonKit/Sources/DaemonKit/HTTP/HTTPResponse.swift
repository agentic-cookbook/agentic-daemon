import Foundation

/// An HTTP/1.1 response — either a normal body response, or a signal to
/// upgrade the connection to Server-Sent Events.
///
/// Regular responses carry `status`, `body`, `contentType`. An SSE upgrade
/// response only carries `filters` metadata the server hands to its
/// configured SSE upgrade handler — the body and content type are ignored
/// because HTTPServer writes the standard SSE handshake itself.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String
    public let kind: Kind

    /// Response kind. Routers pick between a normal response and an SSE upgrade.
    public enum Kind: Sendable, Equatable {
        /// Normal HTTP response: send body, close the connection.
        case immediate
        /// Upgrade to Server-Sent Events: send the SSE handshake bytes, keep
        /// the connection open, hand it off to the server's SSE upgrade handler.
        /// The `filters` dictionary is arbitrary metadata the handler can use
        /// (e.g. stenographer uses `"session_id"` to scope streams).
        case sseUpgrade(filters: [String: String])
    }

    public init(status: Int, body: Data, contentType: String, kind: Kind = .immediate) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.kind = kind
    }

    /// Serializes a normal response to HTTP/1.1 wire format.
    /// SSE-upgrade responses should never reach this path — HTTPServer writes
    /// the handshake bytes directly.
    public func serialize() -> Data {
        var header = "HTTP/1.1 \(status) \(Self.statusText(for: status))\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    // MARK: - Factory methods

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body, contentType: "application/json")
    }

    public static func notFound(_ message: String = "Not found") -> HTTPResponse {
        HTTPResponse(
            status: 404,
            body: Data(#"{"error":"\#(message)"}"#.utf8),
            contentType: "application/json"
        )
    }

    public static func error(_ message: String, status: Int = 500) -> HTTPResponse {
        HTTPResponse(
            status: status,
            body: Data(#"{"error":"\#(message)"}"#.utf8),
            contentType: "application/json"
        )
    }

    /// Request a Server-Sent Events upgrade. HTTPServer will only honor this
    /// when it has an `sseUpgradeHandler` configured; otherwise a 501 is
    /// returned to the client.
    ///
    /// - Parameter filters: Arbitrary string metadata the upgrade handler can
    ///   use to scope broadcasts (e.g. `["session_id": "abc"]`).
    public static func sseUpgrade(filters: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            body: Data(),
            contentType: "text/event-stream",
            kind: .sseUpgrade(filters: filters)
        )
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        default:  "Unknown"
        }
    }
}
