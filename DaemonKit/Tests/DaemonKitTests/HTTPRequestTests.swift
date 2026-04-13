import Testing
import Foundation
@testable import DaemonKit

@Suite("HTTPRequest")
struct HTTPRequestTests {

    @Test("Parses simple GET request")
    func parsesSimpleGet() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.method == "GET")
        #expect(request.path == "/health")
        #expect(request.queryItems.isEmpty)
    }

    @Test("Parses query parameters")
    func parsesQueryParams() throws {
        let raw = "GET /jobs?status=active&limit=10 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.path == "/jobs")
        #expect(request.queryItems["status"] == "active")
        #expect(request.queryItems["limit"] == "10")
    }

    @Test("Parses headers")
    func parsesHeaders() throws {
        let raw = "GET / HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n\r\n"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.headers["host"] == "localhost")
        #expect(request.headers["accept"] == "application/json")
    }

    @Test("Parses POST with content-length body")
    func parsesPostBody() throws {
        let body = #"{"name":"test"}"#
        let raw = "POST /jobs HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.method == "POST")
        #expect(request.body == Data(body.utf8))
    }

    @Test("Throws on empty data")
    func throwsOnEmpty() {
        #expect(throws: HTTPRequestParser.ParseError.self) {
            try HTTPRequestParser.parse(Data())
        }
    }

    @Test("Throws on malformed request line")
    func throwsOnMalformed() {
        #expect(throws: HTTPRequestParser.ParseError.self) {
            try HTTPRequestParser.parse(Data("GARBAGE\r\n\r\n".utf8))
        }
    }

    @Test("pathComponents splits correctly")
    func pathComponents() throws {
        let raw = "GET /sessions/abc/events HTTP/1.1\r\n\r\n"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.pathComponents == ["sessions", "abc", "events"])
    }

    @Test("query helper returns nil for missing key")
    func queryHelperNil() throws {
        let raw = "GET /test HTTP/1.1\r\n\r\n"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.query("missing") == nil)
    }

    @Test("queryInt returns default for missing key")
    func queryIntDefault() throws {
        let raw = "GET /test HTTP/1.1\r\n\r\n"
        let request = try HTTPRequestParser.parse(Data(raw.utf8))
        #expect(request.queryInt("limit", default: 50) == 50)
    }
}
