# DaemonKit CLI + HTTP Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add HTTP server, CLI connection helpers, and output formatters to DaemonKit so clients can build management CLIs and functional tests against their daemons.

**Architecture:** Three groups of functionality in the existing DaemonKit target: (1) an NWListener-based HTTP/1.1 server with a router protocol, (2) XPC + HTTP connection wrappers for CLI tools, (3) terminal output formatters. DaemonEngine gains an optional `httpRouter` parameter and starts the HTTP server when `httpPort` is configured.

**Tech Stack:** Swift 6, Network.framework (NWListener/NWConnection), Foundation

---

## File Structure

### New files in DaemonKit/Sources/DaemonKit/

| File | Responsibility |
|------|---------------|
| `HTTP/HTTPRequest.swift` | Parsed request struct + HTTP/1.1 parser |
| `HTTP/HTTPResponse.swift` | Response struct + factory methods + serialization |
| `HTTP/HTTPServer.swift` | NWListener server, localhost-only, dispatches to router |
| `HTTP/DaemonHTTPRouter.swift` | Router protocol clients implement |
| `CLI/DaemonConnection.swift` | XPC connection wrapper for CLI tools |
| `CLI/DaemonHTTPClient.swift` | Synchronous HTTP client for CLIs and tests |
| `CLI/CLIFormatters.swift` | padRight, formatDuration, formatTimestamp, printJSON, die |

### Modified files

| File | Change |
|------|--------|
| `DaemonConfiguration.swift` | Add `httpPort: UInt16?` field |
| `DaemonEngine.swift` | Accept optional `httpRouter`, start/stop `HTTPServer` |

### New test files in DaemonKit/Tests/DaemonKitTests/

| File | Tests |
|------|-------|
| `HTTPRequestTests.swift` | Parser: method, path, query params, headers, malformed input |
| `HTTPResponseTests.swift` | Factory methods, serialization |
| `HTTPServerTests.swift` | Start server, send request via URLSession, verify response |
| `CLIFormatterTests.swift` | padRight, formatDuration, formatTimestamp |
| `DaemonHTTPClientTests.swift` | GET against real HTTPServer, JSON decoding |

---

### Task 1: HTTPRequest + Parser

**Files:**
- Create: `DaemonKit/Sources/DaemonKit/HTTP/HTTPRequest.swift`
- Test: `DaemonKit/Tests/DaemonKitTests/HTTPRequestTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// DaemonKit/Tests/DaemonKitTests/HTTPRequestTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DaemonKit && swift test --filter HTTPRequestTests 2>&1 | tail -5`
Expected: Compilation error — `HTTPRequestParser` not defined

- [ ] **Step 3: Implement HTTPRequest + parser**

```swift
// DaemonKit/Sources/DaemonKit/HTTP/HTTPRequest.swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd DaemonKit && swift test --filter HTTPRequestTests 2>&1 | tail -5`
Expected: All 9 tests pass

- [ ] **Step 5: Commit**

```
git add DaemonKit/Sources/DaemonKit/HTTP/HTTPRequest.swift DaemonKit/Tests/DaemonKitTests/HTTPRequestTests.swift
git commit -m "feat(DaemonKit): add HTTPRequest struct and parser"
```

---

### Task 2: HTTPResponse

**Files:**
- Create: `DaemonKit/Sources/DaemonKit/HTTP/HTTPResponse.swift`
- Test: `DaemonKit/Tests/DaemonKitTests/HTTPResponseTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// DaemonKit/Tests/DaemonKitTests/HTTPResponseTests.swift
import Testing
import Foundation
@testable import DaemonKit

@Suite("HTTPResponse")
struct HTTPResponseTests {

    @Test("json factory encodes value with correct content type")
    func jsonFactory() {
        struct TestData: Codable { let name: String; let count: Int }
        let response = HTTPResponse.json(TestData(name: "test", count: 42))
        #expect(response.status == 200)
        #expect(response.contentType == "application/json")
        let decoded = try? JSONDecoder().decode(TestData.self, from: response.body)
        #expect(decoded?.name == "test")
        #expect(decoded?.count == 42)
    }

    @Test("json factory accepts custom status code")
    func jsonCustomStatus() {
        let response = HTTPResponse.json(["ok": true], status: 201)
        #expect(response.status == 201)
    }

    @Test("notFound returns 404")
    func notFound() {
        let response = HTTPResponse.notFound()
        #expect(response.status == 404)
        #expect(response.contentType == "application/json")
    }

    @Test("error returns specified status")
    func error() {
        let response = HTTPResponse.error("bad", status: 500)
        #expect(response.status == 500)
        let body = String(data: response.body, encoding: .utf8) ?? ""
        #expect(body.contains("bad"))
    }

    @Test("serialize produces valid HTTP response bytes")
    func serialize() {
        let response = HTTPResponse.json(["key": "value"])
        let data = response.serialize()
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(str.contains("Content-Type: application/json"))
        #expect(str.contains("Content-Length:"))
        #expect(str.contains("Connection: close"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DaemonKit && swift test --filter HTTPResponseTests 2>&1 | tail -5`
Expected: Compilation error — `HTTPResponse` not defined

- [ ] **Step 3: Implement HTTPResponse**

```swift
// DaemonKit/Sources/DaemonKit/HTTP/HTTPResponse.swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd DaemonKit && swift test --filter HTTPResponseTests 2>&1 | tail -5`
Expected: All 5 tests pass

- [ ] **Step 5: Commit**

```
git add DaemonKit/Sources/DaemonKit/HTTP/HTTPResponse.swift DaemonKit/Tests/DaemonKitTests/HTTPResponseTests.swift
git commit -m "feat(DaemonKit): add HTTPResponse struct with factory methods"
```

---

### Task 3: DaemonHTTPRouter Protocol + HTTPServer

**Files:**
- Create: `DaemonKit/Sources/DaemonKit/HTTP/DaemonHTTPRouter.swift`
- Create: `DaemonKit/Sources/DaemonKit/HTTP/HTTPServer.swift`
- Test: `DaemonKit/Tests/DaemonKitTests/HTTPServerTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// DaemonKit/Tests/DaemonKitTests/HTTPServerTests.swift
import Testing
import Foundation
@testable import DaemonKit

/// Stub router that returns a fixed response for /health, 404 otherwise.
struct StubHTTPRouter: DaemonHTTPRouter {
    func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/health" {
            return .json(["status": "ok"])
        }
        return .notFound()
    }
}

@Suite("HTTPServer", .serialized)
struct HTTPServerTests {

    @Test("Server starts and responds to GET /health")
    func startsAndResponds() async throws {
        let server = HTTPServer(port: 0, router: StubHTTPRouter(), subsystem: "test")
        let port = try server.startAndWait()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 200)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["status"] as? String == "ok")
    }

    @Test("Server returns 404 for unknown path")
    func returns404() async throws {
        let server = HTTPServer(port: 0, router: StubHTTPRouter(), subsystem: "test")
        let port = try server.startAndWait()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/nonexistent")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        #expect(httpResponse.statusCode == 404)
    }

    @Test("Server passes query parameters to router")
    func passesQueryParams() async throws {
        struct QueryEchoRouter: DaemonHTTPRouter {
            func handle(request: HTTPRequest) async -> HTTPResponse {
                .json(request.queryItems)
            }
        }
        let server = HTTPServer(port: 0, router: QueryEchoRouter(), subsystem: "test")
        let port = try server.startAndWait()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/test?foo=bar&n=42")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(json?["foo"] == "bar")
        #expect(json?["n"] == "42")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DaemonKit && swift test --filter HTTPServerTests 2>&1 | tail -5`
Expected: Compilation error — `DaemonHTTPRouter`, `HTTPServer` not defined

- [ ] **Step 3: Implement DaemonHTTPRouter protocol**

```swift
// DaemonKit/Sources/DaemonKit/HTTP/DaemonHTTPRouter.swift
import Foundation

/// Protocol for routing HTTP requests. Clients implement this to define their
/// daemon's HTTP API endpoints.
public protocol DaemonHTTPRouter: Sendable {
    /// Handle an HTTP request and return a response.
    func handle(request: HTTPRequest) async -> HTTPResponse
}
```

- [ ] **Step 4: Implement HTTPServer**

```swift
// DaemonKit/Sources/DaemonKit/HTTP/HTTPServer.swift
import Foundation
import Network
import os

/// A minimal HTTP/1.1 server that listens on localhost and dispatches
/// requests to a ``DaemonHTTPRouter``.
///
/// Uses `NWListener` from Network.framework. Binds to 127.0.0.1 only.
/// No TLS, no keep-alive — each request gets a response then the connection closes.
public final class HTTPServer: @unchecked Sendable {
    private let logger: Logger
    private let router: any DaemonHTTPRouter
    private var listener: NWListener?
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "DaemonKit.HTTPServer", qos: .utility)

    /// The actual port the server is listening on. Valid after `startAndWait()`.
    public private(set) var actualPort: UInt16 = 0
    private let readySemaphore = DispatchSemaphore(value: 0)

    public init(port: UInt16, router: any DaemonHTTPRouter, subsystem: String) {
        self.requestedPort = port
        self.router = router
        self.logger = Logger(subsystem: subsystem, category: "HTTPServer")
    }

    /// Start the server. Use port 0 for OS-assigned port.
    public func start() throws {
        let params = NWParameters.tcp
        if requestedPort != 0 {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: requestedPort)!
            )
        }

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.handleConnection(conn) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener?.port?.rawValue {
                    self.actualPort = port
                }
                self.logger.info("HTTP server listening on 127.0.0.1:\(self.actualPort)")
                self.readySemaphore.signal()
            case .failed(let error):
                self.logger.error("HTTP server failed: \(error)")
                self.readySemaphore.signal()
            default: break
            }
        }
        l.start(queue: queue)
        self.listener = l
    }

    /// Start and block until the server is ready. Returns the port in use.
    @discardableResult
    public func startAndWait(timeout: TimeInterval = 5) throws -> UInt16 {
        try start()
        readySemaphore.wait()
        return actualPort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }

            guard let request = try? HTTPRequestParser.parse(data) else {
                self.sendAndClose(.error("Bad request", status: 400), on: connection)
                return
            }

            Task { [self] in
                let response = await self.router.handle(request: request)
                self.sendAndClose(response, on: connection)
            }
        }
    }

    private func sendAndClose(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd DaemonKit && swift test --filter HTTPServerTests 2>&1 | tail -5`
Expected: All 3 tests pass

- [ ] **Step 6: Commit**

```
git add DaemonKit/Sources/DaemonKit/HTTP/DaemonHTTPRouter.swift DaemonKit/Sources/DaemonKit/HTTP/HTTPServer.swift DaemonKit/Tests/DaemonKitTests/HTTPServerTests.swift
git commit -m "feat(DaemonKit): add HTTPServer with NWListener and DaemonHTTPRouter protocol"
```

---

### Task 4: CLI Formatters

**Files:**
- Create: `DaemonKit/Sources/DaemonKit/CLI/CLIFormatters.swift`
- Test: `DaemonKit/Tests/DaemonKitTests/CLIFormatterTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// DaemonKit/Tests/DaemonKitTests/CLIFormatterTests.swift
import Testing
import Foundation
@testable import DaemonKit

@Suite("CLIFormatters")
struct CLIFormatterTests {

    // MARK: - padRight

    @Test("padRight pads short string")
    func padRightPads() {
        #expect(padRight("hi", 10) == "hi        ")
    }

    @Test("padRight truncates long string")
    func padRightTruncates() {
        #expect(padRight("hello world", 6) == "hell…")
    }

    @Test("padRight handles exact width")
    func padRightExact() {
        #expect(padRight("abc", 3) == "abc")
    }

    // MARK: - formatDuration

    @Test("formatDuration under a minute")
    func durationSeconds() {
        #expect(formatDuration(42) == "42s")
    }

    @Test("formatDuration minutes")
    func durationMinutes() {
        #expect(formatDuration(125) == "2m 5s")
    }

    @Test("formatDuration hours")
    func durationHours() {
        #expect(formatDuration(3725) == "1h 2m")
    }

    // MARK: - formatTimestamp

    @Test("formatTimestamp with Date shows time")
    func timestampDate() {
        let date = Date()
        let result = formatTimestamp(date)
        // Today's date should be HH:mm:ss format (8 chars)
        #expect(result.count == 8)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DaemonKit && swift test --filter CLIFormatterTests 2>&1 | tail -5`
Expected: Compilation error — `padRight`, `formatDuration`, `formatTimestamp` not defined

- [ ] **Step 3: Implement CLIFormatters**

```swift
// DaemonKit/Sources/DaemonKit/CLI/CLIFormatters.swift
import Foundation

/// Pad or truncate a string to a fixed width. Strings longer than `width`
/// are truncated with an ellipsis.
public func padRight(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    if s.count > width {
        return String(s.prefix(width - 1)) + "…"
    }
    return s.padding(toLength: width, withPad: " ", startingAt: 0)
}

/// Format seconds as "42s", "3m 12s", or "2h 15m".
public func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}

/// Format a Date for terminal display.
/// Today → "HH:mm:ss", older → "MM-dd HH:mm:ss".
public func formatTimestamp(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm:ss"
    return fmt.string(from: date)
}

/// Format an ISO 8601 string for terminal display.
public func formatTimestamp(_ isoString: String) -> String {
    let parsers: [DateFormatter] = {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        iso.locale = Locale(identifier: "en_US_POSIX")
        let sqlite = DateFormatter()
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        return [iso, sqlite]
    }()

    for parser in parsers {
        if let date = parser.date(from: isoString) {
            return formatTimestamp(date)
        }
    }
    return String(isoString.prefix(19))
}

/// Print an Encodable value as pretty-printed JSON to stdout.
public func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

/// Print error to stderr and exit.
public func die(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd DaemonKit && swift test --filter CLIFormatterTests 2>&1 | tail -5`
Expected: All 8 tests pass

- [ ] **Step 5: Commit**

```
git add DaemonKit/Sources/DaemonKit/CLI/CLIFormatters.swift DaemonKit/Tests/DaemonKitTests/CLIFormatterTests.swift
git commit -m "feat(DaemonKit): add CLI output formatters"
```

---

### Task 5: DaemonConnection (XPC wrapper) + DaemonHTTPClient

**Files:**
- Create: `DaemonKit/Sources/DaemonKit/CLI/DaemonConnection.swift`
- Create: `DaemonKit/Sources/DaemonKit/CLI/DaemonHTTPClient.swift`
- Test: `DaemonKit/Tests/DaemonKitTests/DaemonHTTPClientTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// DaemonKit/Tests/DaemonKitTests/DaemonHTTPClientTests.swift
import Testing
import Foundation
@testable import DaemonKit

@Suite("DaemonHTTPClient", .serialized)
struct DaemonHTTPClientTests {

    /// Router that returns a known JSON payload for /health.
    struct HealthRouter: DaemonHTTPRouter {
        func handle(request: HTTPRequest) async -> HTTPResponse {
            if request.path == "/health" {
                return .json(["status": "ok", "uptime": 42.0])
            }
            return .notFound()
        }
    }

    @Test("get decodes JSON response")
    func getDecodesJSON() throws {
        let server = HTTPServer(port: 0, router: HealthRouter(), subsystem: "test")
        let port = try server.startAndWait()
        defer { server.stop() }

        let client = DaemonHTTPClient(baseURL: "http://127.0.0.1:\(port)")
        struct Health: Decodable { let status: String; let uptime: Double }
        let health = client.get("/health", as: Health.self)
        #expect(health?.status == "ok")
        #expect(health?.uptime == 42.0)
    }

    @Test("get returns nil for 404")
    func getReturnsNilFor404() throws {
        let server = HTTPServer(port: 0, router: HealthRouter(), subsystem: "test")
        let port = try server.startAndWait()
        defer { server.stop() }

        let client = DaemonHTTPClient(baseURL: "http://127.0.0.1:\(port)")
        struct Anything: Decodable { let x: Int }
        #expect(client.get("/nonexistent", as: Anything.self) == nil)
    }

    @Test("get returns nil when server is not running")
    func getReturnsNilNoServer() {
        let client = DaemonHTTPClient(baseURL: "http://127.0.0.1:19999")
        struct Anything: Decodable { let x: Int }
        #expect(client.get("/health", as: Anything.self) == nil)
    }

    @Test("getData returns raw bytes")
    func getDataReturnsBytes() throws {
        let server = HTTPServer(port: 0, router: HealthRouter(), subsystem: "test")
        let port = try server.startAndWait()
        defer { server.stop() }

        let client = DaemonHTTPClient(baseURL: "http://127.0.0.1:\(port)")
        let data = client.getData("/health")
        #expect(data != nil)
        #expect(data!.count > 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DaemonKit && swift test --filter DaemonHTTPClientTests 2>&1 | tail -5`
Expected: Compilation error — `DaemonHTTPClient` not defined

- [ ] **Step 3: Implement DaemonConnection**

```swift
// DaemonKit/Sources/DaemonKit/CLI/DaemonConnection.swift
import Foundation

/// Wraps NSXPCConnection for CLI tools. Provides typed proxy access to a
/// daemon's XPC protocol.
///
/// Usage:
/// ```swift
/// let conn = DaemonConnection(machServiceName: "com.example.my-daemon.xpc")
/// conn.connect()
/// let proxy = try conn.xpcProxy(as: MyDaemonXPC.self)
/// // call proxy methods...
/// ```
public final class DaemonConnection: @unchecked Sendable {
    private let machServiceName: String
    private var connection: NSXPCConnection?

    public init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    public var isConnected: Bool { connection != nil }

    /// Open the XPC connection. Safe to call multiple times.
    public func connect() {
        guard connection == nil else { return }
        let conn = NSXPCConnection(machServiceName: machServiceName)
        conn.invalidationHandler = { [weak self] in self?.connection = nil }
        conn.interruptionHandler = { [weak self] in self?.connection = nil }
        conn.resume()
        connection = conn
    }

    /// Close the XPC connection.
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    /// Set the remote object interface. Call before `xpcProxy(as:)`.
    public func setInterface(_ interface: NSXPCInterface) {
        connection?.remoteObjectInterface = interface
    }

    /// Get the remote proxy, cast to the specified protocol type.
    public func xpcProxy<T>(as type: T.Type) throws -> T {
        guard let conn = connection else {
            throw DaemonConnectionError.notConnected
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            fputs("XPC error: \(error.localizedDescription)\n", stderr)
        }) as? T else {
            throw DaemonConnectionError.proxyUnavailable
        }
        return proxy
    }
}

public enum DaemonConnectionError: Error {
    case notConnected
    case proxyUnavailable
}
```

- [ ] **Step 4: Implement DaemonHTTPClient**

```swift
// DaemonKit/Sources/DaemonKit/CLI/DaemonHTTPClient.swift
import Foundation

/// Synchronous HTTP client for CLI tools and functional tests.
/// Connects to a daemon's HTTP server for querying status.
public struct DaemonHTTPClient: Sendable {
    private let baseURL: String
    private let timeout: TimeInterval

    public init(baseURL: String, timeout: TimeInterval = 2) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// GET a path and decode the JSON response. Returns nil on any failure.
    public func get<T: Decodable>(_ path: String, as type: T.Type) -> T? {
        guard let data = getData(path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// GET a path and return the raw response body. Returns nil on any failure.
    public func getData(_ path: String) -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = data
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        return result
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd DaemonKit && swift test --filter DaemonHTTPClientTests 2>&1 | tail -5`
Expected: All 4 tests pass

- [ ] **Step 6: Commit**

```
git add DaemonKit/Sources/DaemonKit/CLI/DaemonConnection.swift DaemonKit/Sources/DaemonKit/CLI/DaemonHTTPClient.swift DaemonKit/Tests/DaemonKitTests/DaemonHTTPClientTests.swift
git commit -m "feat(DaemonKit): add DaemonConnection (XPC) and DaemonHTTPClient"
```

---

### Task 6: Wire HTTP into DaemonConfiguration + DaemonEngine

**Files:**
- Modify: `DaemonKit/Sources/DaemonKit/DaemonConfiguration.swift`
- Modify: `DaemonKit/Sources/DaemonKit/DaemonEngine.swift`
- Test: `DaemonKit/Tests/DaemonKitTests/DaemonConfigurationTests.swift` (add test)

- [ ] **Step 1: Add httpPort test**

Add to the existing `DaemonConfigurationTests.swift`:

```swift
    @Test("httpPort defaults to nil")
    func httpPortDefault() {
        let config = DaemonConfiguration(
            identifier: "com.example.test",
            supportDirectory: URL(fileURLWithPath: "/tmp/test")
        )
        #expect(config.httpPort == nil)
    }

    @Test("httpPort stores explicit value")
    func httpPortExplicit() {
        let config = DaemonConfiguration(
            identifier: "com.example.test",
            supportDirectory: URL(fileURLWithPath: "/tmp/test"),
            httpPort: 8080
        )
        #expect(config.httpPort == 8080)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd DaemonKit && swift test --filter DaemonConfigurationTests 2>&1 | tail -5`
Expected: Compilation error — `httpPort` not a member of `DaemonConfiguration`

- [ ] **Step 3: Add httpPort to DaemonConfiguration**

In `DaemonKit/Sources/DaemonKit/DaemonConfiguration.swift`, add the field and init parameter.

The `httpPort` property goes after `tickInterval`:
```swift
    /// HTTP server port for management API. Pass nil to disable HTTP.
    public let httpPort: UInt16?
```

The init gains a new parameter after `tickInterval`:
```swift
    public init(
        identifier: String,
        supportDirectory: URL,
        machServiceName: String? = nil,
        crashReportProcessName: String? = nil,
        crashRetentionDays: Int = 30,
        tickInterval: TimeInterval = 1.0,
        httpPort: UInt16? = nil
    ) {
        self.identifier = identifier
        self.supportDirectory = supportDirectory
        self.machServiceName = machServiceName
        self.crashReportProcessName = crashReportProcessName ?? identifier.components(separatedBy: ".").last ?? identifier
        self.crashRetentionDays = crashRetentionDays
        self.tickInterval = tickInterval
        self.httpPort = httpPort
    }
```

- [ ] **Step 4: Update DaemonEngine to accept httpRouter and start HTTPServer**

In `DaemonKit/Sources/DaemonKit/DaemonEngine.swift`:

Add a stored property after `xpcServer`:
```swift
    private var httpServer: HTTPServer?
```

Change the `run` signature to:
```swift
    public func run(
        xpcExportedObject: AnyObject? = nil,
        xpcInterface: NSXPCInterface? = nil,
        httpRouter: (any DaemonHTTPRouter)? = nil
    ) async {
```

After the XPC server block (after `self.xpcServer = server`), add:
```swift
        if let httpPort = configuration.httpPort, let router = httpRouter {
            let server = HTTPServer(port: httpPort, router: router, subsystem: configuration.identifier)
            do {
                try server.start()
                self.httpServer = server
            } catch {
                logger.error("Failed to start HTTP server: \(error)")
            }
        }
```

In the shutdown path (before `logger.info("Daemon stopped")`), add:
```swift
        httpServer?.stop()
```

- [ ] **Step 5: Run all DaemonKit tests**

Run: `cd DaemonKit && swift test 2>&1 | tail -5`
Expected: All tests pass (existing + new DaemonConfiguration tests)

- [ ] **Step 6: Commit**

```
git add DaemonKit/Sources/DaemonKit/DaemonConfiguration.swift DaemonKit/Sources/DaemonKit/DaemonEngine.swift DaemonKit/Tests/DaemonKitTests/DaemonConfigurationTests.swift
git commit -m "feat(DaemonKit): wire HTTP server into DaemonEngine and DaemonConfiguration"
```

---

### Task 7: Update AgenticDaemon for new DaemonConfiguration signature

**Files:**
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/AgenticDaemonController.swift`

- [ ] **Step 1: Verify AgenticDaemon still builds**

Run: `cd AgenticDaemon && swift build 2>&1 | tail -5`
Expected: Should build clean — `httpPort` has a default value of `nil` so existing call sites are unaffected. If it fails, the `DaemonConfiguration` init call in `AgenticDaemonController.swift` may need updating.

- [ ] **Step 2: Run AgenticDaemon tests**

Run: `cd AgenticDaemon && swift test 2>&1 | grep "Test run with"`
Expected: All tests pass

- [ ] **Step 3: Commit (only if changes were needed)**

```
git add AgenticDaemon/Sources/AgenticDaemonLib/AgenticDaemonController.swift
git commit -m "fix: update AgenticDaemon for DaemonConfiguration httpPort parameter"
```

---

### Task 8: Full verification

- [ ] **Step 1: Run DaemonKit full test suite**

Run: `cd DaemonKit && swift test 2>&1 | tail -3`
Expected: All tests pass

- [ ] **Step 2: Run AgenticDaemon full test suite**

Run: `cd AgenticDaemon && swift test 2>&1 | grep "Test run with"`
Expected: All tests pass

- [ ] **Step 3: Build both in release mode**

Run: `cd DaemonKit && swift build -c release 2>&1 | tail -3 && cd ../AgenticDaemon && swift build -c release 2>&1 | tail -3`
Expected: Both build clean
