import Testing
import Foundation
import Network
@testable import DaemonKit

/// Router that upgrades /stream requests to SSE, echoing query params as filters.
private struct SSEUpgradeRouter: DaemonHTTPRouter {
    func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/stream" {
            return .sseUpgrade(filters: request.queryItems)
        }
        return .notFound()
    }
}

private struct NeverUpgradeRouter: DaemonHTTPRouter {
    func handle(request: HTTPRequest) async -> HTTPResponse {
        .sseUpgrade()
    }
}

@Suite("HTTPServer SSE upgrade", .serialized)
struct HTTPServerSSETests {

    @Test("SSE upgrade with configured handler sends handshake and invokes handler")
    func upgradeInvokesHandler() async throws {
        let captured = CapturedUpgrade()
        let sse = SSEBroadcaster(subsystem: "http-sse-test")
        let server = HTTPServer(
            port: 0,
            router: SSEUpgradeRouter(),
            subsystem: "http-sse-test",
            sseUpgradeHandler: { conn, req, filters in
                captured.record(request: req, filters: filters)
                sse.addClient(conn, filters: filters)
            }
        )
        let port = try server.startAndWait()
        defer {
            sse.shutdown()
            server.stop()
        }

        // Open raw TCP, issue GET /stream?session_id=abc, read the handshake
        let (client, response) = try await rawHTTPConnect(
            port: port,
            path: "/stream?session_id=abc"
        )
        defer { client.cancel() }

        let responseText = String(data: response, encoding: .utf8) ?? ""
        #expect(responseText.contains("HTTP/1.1 200 OK"))
        #expect(responseText.contains("Content-Type: text/event-stream"))

        // Wait for the upgrade handler to run
        var attempts = 0
        while captured.filters == nil && attempts < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        #expect(captured.filters?["session_id"] == "abc")

        // Now broadcast — client should receive
        sse.broadcast(eventType: "test", payload: Data("{}".utf8))

        var broadcastBytes = Data()
        var broadcastAttempts = 0
        while !String(data: broadcastBytes, encoding: .utf8).map({ $0.contains("event: test") }).yesOrFalse()
            && broadcastAttempts < 20 {
            let chunk = try await readChunk(from: client, timeout: 0.3)
            broadcastBytes.append(chunk)
            broadcastAttempts += 1
            if chunk.isEmpty { break }
        }
        let text = String(data: broadcastBytes, encoding: .utf8) ?? ""
        #expect(text.contains("event: test"))
    }

    @Test("SSE upgrade without handler returns 501")
    func upgradeWithoutHandlerReturns501() async throws {
        let server = HTTPServer(
            port: 0,
            router: NeverUpgradeRouter(),
            subsystem: "http-sse-test"
        )
        let port = try server.startAndWait()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/stream")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        #expect(httpResponse.statusCode == 501)
    }
}

// MARK: - Helpers

private final class CapturedUpgrade: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: HTTPRequest?
    private var _filters: [String: String]?
    var filters: [String: String]? { lock.withLock { _filters } }
    func record(request: HTTPRequest, filters: [String: String]) {
        lock.withLock {
            _request = request
            _filters = filters
        }
    }
}

/// Opens a raw TCP connection to localhost, sends an HTTP GET, returns
/// (clientConnection, initialResponseChunk).
private func rawHTTPConnect(port: UInt16, path: String) async throws -> (NWConnection, Data) {
    let client = NWConnection(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
    )
    let ready = AsyncEvent()
    client.stateUpdateHandler = { state in
        if case .ready = state { ready.fire() }
    }
    client.start(queue: .global(qos: .utility))
    await ready.wait()

    let req = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    let sent = AsyncEvent()
    client.send(content: Data(req.utf8), completion: .contentProcessed { _ in sent.fire() })
    await sent.wait()

    let initial = try await readChunk(from: client, timeout: 2.0)
    return (client, initial)
}

private func readChunk(from conn: NWConnection, timeout: TimeInterval) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        let box = ReadResumeBox(continuation: cont)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let error { box.resume(throwing: error); return }
            box.resume(returning: data ?? Data())
        }
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            box.resume(returning: Data())
        }
    }
}

private final class ReadResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Data, Error>

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(throwing: error)
    }
}

private final class AsyncEvent: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let conts: [CheckedContinuation<Void, Never>] = lock.withLock {
            if fired { return [] }
            fired = true
            let c = continuations
            continuations.removeAll()
            return c
        }
        for c in conts { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if fired {
                    cont.resume()
                } else {
                    continuations.append(cont)
                }
            }
        }
    }
}

private extension Optional where Wrapped == Bool {
    func yesOrFalse() -> Bool { self ?? false }
}
