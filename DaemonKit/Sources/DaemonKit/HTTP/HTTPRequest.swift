import Foundation

/// A parsed HTTP/1.1 request.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let queryItems: [String: String]
    public let headers: [String: String]
    public let body: Data?

    /// Path split into components: "/sessions/abc/events" → ["sessions","abc","events"]
    public var pathComponents: [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Returns query param or nil.
    public func query(_ key: String) -> String? { queryItems[key] }

    /// Returns query param as Int, or default.
    public func queryInt(_ key: String, default def: Int = 0) -> Int {
        Int(queryItems[key] ?? "") ?? def
    }
}

/// Minimal HTTP/1.1 request parser.
public enum HTTPRequestParser {
    public enum ParseError: Error {
        case incomplete
        case malformed
    }

    public static func parse(_ data: Data) throws -> HTTPRequest {
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            throw ParseError.incomplete
        }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw ParseError.incomplete
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { throw ParseError.malformed }

        let method = parts[0]
        let rawPath = parts[1]

        var path = rawPath
        var queryItems: [String: String] = [:]

        if let qIdx = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<qIdx])
            let queryString = String(rawPath[rawPath.index(after: qIdx)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    queryItems[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                } else if kv.count == 1 {
                    queryItems[kv[0].removingPercentEncoding ?? kv[0]] = ""
                }
            }
        }

        var headers: [String: String] = [:]
        var bodyStartIndex: String.Index?
        for line in lines.dropFirst() {
            if line.isEmpty {
                if let range = raw.range(of: "\r\n\r\n") {
                    bodyStartIndex = range.upperBound
                }
                break
            }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        var body: Data?
        if let startIdx = bodyStartIndex {
            let bodyString = String(raw[startIdx...])
            if !bodyString.isEmpty {
                body = Data(bodyString.utf8)
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }
}
