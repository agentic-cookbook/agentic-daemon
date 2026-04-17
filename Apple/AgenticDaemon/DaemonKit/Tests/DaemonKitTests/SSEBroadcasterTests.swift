import Testing
import Foundation
import Network
@testable import DaemonKit

@Suite("SSEBroadcaster", .serialized)
struct SSEBroadcasterTests {

    @Test("starts with zero clients")
    func startsEmpty() {
        let sse = SSEBroadcaster(subsystem: "test")
        #expect(sse.clientCount == 0)
    }

    @Test("addClient/removeClient track count")
    func addRemoveClient() async throws {
        let sse = SSEBroadcaster(subsystem: "test")
        let (client1, _) = try await makeLoopbackPair()
        let id = sse.addClient(client1, filters: ["scope": "a"])
        #expect(sse.clientCount == 1)
        sse.removeClient(id: id)
        #expect(sse.clientCount == 0)
        client1.cancel()
    }

    @Test("shutdown cancels all connections and clears clients")
    func shutdownClears() async throws {
        let sse = SSEBroadcaster(subsystem: "test")
        let (c1, _) = try await makeLoopbackPair()
        let (c2, _) = try await makeLoopbackPair()
        sse.addClient(c1)
        sse.addClient(c2)
        #expect(sse.clientCount == 2)
        sse.shutdown()
        #expect(sse.clientCount == 0)
    }

    @Test("broadcast delivers SSE-formatted payload to matching clients")
    func broadcastDelivers() async throws {
        let sse = SSEBroadcaster(subsystem: "test")
        let (serverConn, client) = try await makeLoopbackPair()
        defer {
            serverConn.cancel()
            client.cancel()
        }

        sse.addClient(serverConn, filters: ["scope": "a"])

        // Broadcast a payload
        let payload = Data(#"{"hello":"world"}"#.utf8)
        sse.broadcast(eventType: "greeting", payload: payload)

        let bytes = try await receiveBytes(from: client, timeout: 2.0)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        #expect(text.contains("event: greeting"))
        #expect(text.contains(#"data: {"hello":"world"}"#))
    }

    @Test("broadcast filter predicate skips non-matching clients")
    func broadcastFilterSkips() async throws {
        let sse = SSEBroadcaster(subsystem: "test")
        let (serverA, clientA) = try await makeLoopbackPair()
        let (serverB, clientB) = try await makeLoopbackPair()
        defer {
            serverA.cancel(); clientA.cancel()
            serverB.cancel(); clientB.cancel()
        }

        sse.addClient(serverA, filters: ["scope": "a"])
        sse.addClient(serverB, filters: ["scope": "b"])

        sse.broadcast(eventType: "evt", payload: Data("{}".utf8)) { filters in
            filters["scope"] == "a"
        }

        // Client A should receive, client B should not (within a reasonable wait).
        let aBytes = try await receiveBytes(from: clientA, timeout: 1.0)
        #expect(!aBytes.isEmpty)

        // Ensure B receives nothing — short wait, expect a timeout-equivalent empty result
        let bBytes = try await receiveBytesOrEmpty(from: clientB, timeout: 0.3)
        #expect(bBytes.isEmpty)
    }

    @Test("broadcast Encodable encodes JSON with snake_case keys")
    func broadcastEncodable() async throws {
        struct Payload: Encodable & Sendable {
            let eventName: String
            let sequenceNumber: Int
        }
        let sse = SSEBroadcaster(subsystem: "test")
        let (serverConn, client) = try await makeLoopbackPair()
        defer {
            serverConn.cancel()
            client.cancel()
        }

        sse.addClient(serverConn)
        try sse.broadcast(eventType: "typed", Payload(eventName: "x", sequenceNumber: 7))

        let bytes = try await receiveBytes(from: client, timeout: 2.0)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        #expect(text.contains("event: typed"))
        #expect(text.contains("\"event_name\":\"x\""))
        #expect(text.contains("\"sequence_number\":7"))
    }

    @Test("sendKeepalive writes comment to clients")
    func keepaliveSends() async throws {
        let sse = SSEBroadcaster(subsystem: "test")
        let (serverConn, client) = try await makeLoopbackPair()
        defer {
            serverConn.cancel()
            client.cancel()
        }
        sse.addClient(serverConn)

        sse.sendKeepalive()

        let bytes = try await receiveBytes(from: client, timeout: 1.0)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        #expect(text == ": keepalive\n\n")
    }

    @Test("handshake bytes contain expected SSE headers")
    func handshakeBytesFormat() {
        let text = String(data: SSEBroadcaster.handshakeBytes, encoding: .utf8) ?? ""
        #expect(text.contains("HTTP/1.1 200 OK"))
        #expect(text.contains("Content-Type: text/event-stream"))
        #expect(text.contains("Cache-Control: no-cache"))
        #expect(text.contains("Connection: keep-alive"))
        // Must NOT carry Content-Length (stream is open-ended)
        #expect(!text.contains("Content-Length"))
    }

    @Test("startKeepalive fires on interval")
    func startKeepaliveFires() async throws {
        let sse = SSEBroadcaster(subsystem: "test")
        let (serverConn, client) = try await makeLoopbackPair()
        defer {
            serverConn.cancel()
            client.cancel()
            sse.stopKeepalive()
        }
        sse.addClient(serverConn)
        sse.startKeepalive(every: 0.15)

        // Expect at least one keepalive within ~500ms
        let bytes = try await receiveBytes(from: client, timeout: 1.5)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        #expect(text.contains(": keepalive"))
    }
}

// MARK: - Loopback pair helpers

/// Create a pair of NWConnections connected to each other on loopback.
/// Returns (serverSide, clientSide).
private func makeLoopbackPair() async throws -> (NWConnection, NWConnection) {
    // Start a one-shot listener
    let listener = try NWListener(using: .tcp)
    let readyServer = CheckedContinuationBox<NWConnection>()
    listener.newConnectionHandler = { conn in
        conn.start(queue: .global(qos: .utility))
        readyServer.resume(with: conn)
    }
    let portReady = CheckedContinuationBox<UInt16>()
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port?.rawValue {
            portReady.resume(with: port)
        }
    }
    listener.start(queue: .global(qos: .utility))

    let port = try await portReady.value
    let clientConn = NWConnection(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: port)!,
        using: .tcp
    )
    let clientReady = CheckedContinuationBox<Void>()
    clientConn.stateUpdateHandler = { state in
        if case .ready = state { clientReady.resume(with: ()) }
    }
    clientConn.start(queue: .global(qos: .utility))

    _ = try await clientReady.value
    let serverConn = try await readyServer.value
    listener.cancel()
    return (serverConn, clientConn)
}

/// Receive bytes from a connection, awaiting data within timeout. Returns
/// empty Data on timeout. Uses a resume-once guard so a late receive
/// callback after a timeout doesn't double-resume the continuation.
private func receiveBytes(from connection: NWConnection, timeout: TimeInterval) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        let box = ResumeOnceBox<Data>(continuation: cont)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            if let error { box.resume(throwing: error); return }
            box.resume(returning: data ?? Data())
        }
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            box.resume(returning: Data())
        }
    }
}

/// Like receiveBytes but returns Data() on timeout without throwing.
private func receiveBytesOrEmpty(from connection: NWConnection, timeout: TimeInterval) async throws -> Data {
    try await receiveBytes(from: connection, timeout: timeout)
}

/// Resume-once guard so the first caller wins and subsequent resumes are ignored.
private final class ResumeOnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Error>

    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
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

/// A one-shot continuation box for bridging NWConnection callbacks to async.
private final class CheckedContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved = false
    private var pending: T?
    private var pendingError: (any Error)?

    var value: T {
        get async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                lock.withLock {
                    if resolved {
                        if let err = pendingError { cont.resume(throwing: err) }
                        else if let v = pending { cont.resume(returning: v) }
                    } else {
                        continuation = cont
                    }
                }
            }
        }
    }

    func resume(with value: T) {
        lock.withLock {
            guard !resolved else { return }
            resolved = true
            pending = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
