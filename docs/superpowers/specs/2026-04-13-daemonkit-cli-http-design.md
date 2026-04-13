# DaemonKit CLI + HTTP Infrastructure

## Goal

Add HTTP server infrastructure and CLI building blocks to DaemonKit so clients can build management CLIs and functional tests against their daemons without reinventing connection boilerplate, output formatting, or HTTP plumbing.

## Architecture

Three groups of functionality, all in the existing DaemonKit library target:

1. **HTTP server** — socket listener, request parsing, response encoding, router protocol
2. **CLI connection** — XPC connection wrapper with HTTP fallback
3. **CLI output helpers** — formatters for terminal output (tables, durations, timestamps, JSON mode)

Clients bring their own XPC protocol, their own HTTP routes, and their own CLI commands. DaemonKit provides the infrastructure they wire into.

## HTTP Server

### Types

**`HTTPRequest`** — Parsed incoming request.
```swift
public struct HTTPRequest: Sendable {
    public let method: String    // "GET", "POST", etc.
    public let path: String      // "/health", "/jobs/my-job"
    public let query: [String: String]  // parsed query params
    public let body: Data?
    public let headers: [String: String]
}
```

**`HTTPResponse`** — What route handlers return.
```swift
public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse
    public static func notFound() -> HTTPResponse
    public static func error(_ message: String, status: Int = 500) -> HTTPResponse
}
```

**`DaemonHTTPRouter` protocol** — Clients implement this to define their routes.
```swift
public protocol DaemonHTTPRouter: Sendable {
    func handle(request: HTTPRequest) async -> HTTPResponse
}
```

**`HTTPServer`** — Listens on a port, parses HTTP/1.1, dispatches to the router. Uses `NWListener` from Network.framework (available macOS 14+, no external dependencies).
```swift
public final class HTTPServer: @unchecked Sendable {
    public init(port: UInt16, router: any DaemonHTTPRouter, subsystem: String)
    public func start() throws
    public func stop()
}
```

### Integration with DaemonEngine

`DaemonConfiguration` gains an optional `httpPort: UInt16?` field (default nil). When set, `DaemonEngine.run()` starts an `HTTPServer` alongside XPC.

Clients provide their HTTP router the same way they provide their XPC handler — passed to `DaemonEngine.run()`:

```swift
await engine.run(
    xpcExportedObject: myXPCHandler,
    xpcInterface: NSXPCInterface(with: MyXPCProtocol.self),
    httpRouter: myHTTPRouter   // new optional parameter
)
```

### Design notes

- Uses `NWListener` + `NWConnection` from Network.framework — no Foundation socket code, no third-party deps.
- HTTP/1.1 only. Parses method, path, headers, content-length body. No chunked encoding, no TLS, no keep-alive (close after response). This is a local management API, not a production web server.
- Binds to `127.0.0.1` only — not externally accessible.
- The router protocol is intentionally simple (single `handle` method). Clients do their own path matching in the implementation, same pattern as claude-watcher's `HTTPRouter`.

## CLI Connection

**`DaemonConnection`** — Connects to a daemon via XPC, with optional HTTP fallback for testing.

```swift
public final class DaemonConnection: @unchecked Sendable {
    public init(machServiceName: String)

    /// Get the XPC proxy, cast to your protocol.
    public func xpcProxy<T>(as protocol: T.Type) throws -> T

    /// Whether the XPC connection is active.
    public var isConnected: Bool { get }

    /// Connect (or reconnect) the XPC connection.
    public func connect()

    /// Disconnect.
    public func disconnect()
}
```

Also provides a simple HTTP client for the fallback/testing path:

**`DaemonHTTPClient`** — Minimal synchronous HTTP client for CLI use.
```swift
public struct DaemonHTTPClient: Sendable {
    public init(baseURL: String)

    /// GET request, returns parsed JSON or nil.
    public func get<T: Decodable>(_ path: String, as type: T.Type) -> T?

    /// GET request, returns raw data or nil.
    public func getData(_ path: String) -> Data?
}
```

This is intentionally synchronous (CLIs are sequential) and minimal — just `URLSession.shared` with a short timeout. Matches what `agenticd` does with `urllib`.

## CLI Output Helpers

Free functions and small structs for terminal output. Extracted from the common patterns in claude-watcher's `CLIFormatters.swift`:

```swift
/// Pad or truncate a string to a fixed width.
public func padRight(_ s: String, _ width: Int) -> String

/// Format seconds as "42s", "3m 12s", or "2h 15m".
public func formatDuration(_ seconds: Double) -> String

/// Format a Date as a human-readable timestamp.
/// Today's dates show "HH:mm:ss", older dates show "MM-dd HH:mm:ss".
public func formatTimestamp(_ date: Date) -> String

/// Format an ISO 8601 string as a human-readable timestamp.
public func formatTimestamp(_ isoString: String) -> String

/// Print an Encodable value as pretty-printed JSON to stdout.
public func printJSON<T: Encodable>(_ value: T)

/// Print to stderr and exit.
public func die(_ message: String) -> Never
```

## New files in DaemonKit

| File | Responsibility |
|------|---------------|
| `HTTP/HTTPRequest.swift` | Request struct |
| `HTTP/HTTPResponse.swift` | Response struct + factory methods |
| `HTTP/HTTPServer.swift` | NWListener-based HTTP/1.1 server |
| `HTTP/DaemonHTTPRouter.swift` | Router protocol |
| `CLI/DaemonConnection.swift` | XPC connection wrapper |
| `CLI/DaemonHTTPClient.swift` | Synchronous HTTP client for CLIs |
| `CLI/CLIFormatters.swift` | Output formatting helpers |

## Changes to existing DaemonKit files

| File | Change |
|------|--------|
| `DaemonConfiguration.swift` | Add `httpPort: UInt16?` field (default nil) |
| `DaemonEngine.swift` | Accept optional `httpRouter` in `run()`, start/stop `HTTPServer` |

## Testing

- `HTTPServer` + `HTTPResponse` + `HTTPRequest`: unit test with a mock router, connect with `URLSession`, verify responses
- `CLIFormatters`: unit tests for `padRight`, `formatDuration`, `formatTimestamp`
- `DaemonHTTPClient`: test against the `HTTPServer` with a stub router
- Functional test pattern: start `HTTPServer` with a test router, exercise routes via `DaemonHTTPClient`, assert responses

XPC-level functional tests remain hard without launchd registration — that's exactly why the HTTP layer exists.

## What clients build on top

A client like agentic-daemon would:

1. Define a struct implementing `DaemonHTTPRouter` with their routes (`/health`, `/jobs`, `/jobs/:name`, etc.)
2. Pass it to `engine.run(httpRouter:)` alongside their XPC handler
3. Build a CLI executable that uses `DaemonConnection` for XPC calls and falls back to `DaemonHTTPClient` for HTTP
4. Use `CLIFormatters` for output

## Out of scope

- TLS, authentication, CORS — this is localhost-only management API
- WebSocket / SSE — not needed for daemon management CLIs
- Argument parsing framework — clients do their own `CommandLine.arguments` parsing or use ArgumentParser
- Automatic route generation from XPC protocol — too magical, clients define both explicitly
