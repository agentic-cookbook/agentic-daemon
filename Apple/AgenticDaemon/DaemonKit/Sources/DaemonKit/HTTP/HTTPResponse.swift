import Foundation

/// An HTTP/1.1 response.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public init(status: Int, body: Data, contentType: String) {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    /// Serializes to HTTP/1.1 wire format.
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

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        default:  "Unknown"
        }
    }
}
