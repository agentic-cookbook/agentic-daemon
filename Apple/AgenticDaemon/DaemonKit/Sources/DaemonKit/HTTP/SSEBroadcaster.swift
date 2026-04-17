import Foundation
import Network
import os

/// Tracks live Server-Sent Events connections and broadcasts to them.
///
/// Construct once per daemon, wire into ``HTTPServer`` via its
/// `sseUpgradeHandler`, and call `broadcast` from any code that produces
/// events clients should see. Supports per-client filter metadata
/// (e.g. stenographer's `session_id` scoping).
///
///     let sse = SSEBroadcaster(subsystem: "com.example.daemon")
///     sse.startKeepalive(every: 30)
///     let server = HTTPServer(
///         port: 8080,
///         router: router,
///         subsystem: "com.example.daemon",
///         sseUpgradeHandler: { conn, req, filters in
///             sse.addClient(conn, filters: filters)
///         })
public final class SSEBroadcaster: @unchecked Sendable {
    private let logger: Logger

    private struct Client {
        let connection: NWConnection
        let filters: [String: String]
    }

    private let lock = NSLock()
    private var clients: [UUID: Client] = [:]
    private var keepaliveTimer: DispatchSourceTimer?
    private let keepaliveQueue = DispatchQueue(label: "DaemonKit.SSEBroadcaster.keepalive", qos: .utility)

    public init(subsystem: String) {
        self.logger = Logger(subsystem: subsystem, category: "SSEBroadcaster")
    }

    /// Currently-connected SSE client count.
    public var clientCount: Int {
        lock.withLock { clients.count }
    }

    // MARK: - Client lifecycle

    /// Register a connection. Call from an HTTPServer `sseUpgradeHandler`.
    /// The broadcaster takes over lifecycle — it installs a state handler
    /// that removes the client when the connection fails or is cancelled.
    @discardableResult
    public func addClient(_ connection: NWConnection, filters: [String: String] = [:]) -> UUID {
        let id = UUID()
        lock.withLock { clients[id] = Client(connection: connection, filters: filters) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeClient(id: id)
            default: break
            }
        }
        logger.info("SSE client connected: \(id.uuidString, privacy: .public), filters: \(filters)")
        return id
    }

    public func removeClient(id: UUID) {
        let removed = lock.withLock { clients.removeValue(forKey: id) }
        if removed != nil {
            logger.info("SSE client disconnected: \(id.uuidString, privacy: .public)")
        }
    }

    // MARK: - Broadcasting

    /// Broadcast a pre-encoded JSON payload as an SSE message.
    /// - Parameters:
    ///   - eventType: Goes into the `event:` line. E.g. `"PreToolUse"`.
    ///   - payload: JSON bytes for the `data:` line.
    ///   - matches: Optional predicate over a client's filter metadata.
    ///     Clients for which it returns `false` are skipped.
    public func broadcast(
        eventType: String,
        payload: Data,
        where matches: (@Sendable ([String: String]) -> Bool)? = nil
    ) {
        guard let payloadString = String(data: payload, encoding: .utf8) else {
            logger.error("SSE broadcast payload is not valid UTF-8")
            return
        }
        let message = Self.formatMessage(eventType: eventType, data: payloadString)
        sendToAll(message, matches: matches)
    }

    /// Convenience: encode any ``Encodable`` value as JSON and broadcast.
    public func broadcast<T: Encodable & Sendable>(
        eventType: String,
        _ value: T,
        where matches: (@Sendable ([String: String]) -> Bool)? = nil
    ) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        broadcast(eventType: eventType, payload: data, where: matches)
    }

    /// Send a keepalive comment (`: keepalive\n\n`) to every connection.
    public func sendKeepalive() {
        let snapshot = lock.withLock { clients }
        guard !snapshot.isEmpty else { return }
        let data = Data(": keepalive\n\n".utf8)
        logger.debug("Sending keepalive to \(snapshot.count) client(s)")
        for (id, client) in snapshot {
            client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.removeClient(id: id) }
            })
        }
    }

    // MARK: - Keepalive timer

    /// Start a periodic keepalive. Safe to call once — subsequent calls
    /// replace the existing timer.
    public func startKeepalive(every interval: TimeInterval = 30) {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: keepaliveQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.sendKeepalive() }
        timer.resume()
        lock.withLock { keepaliveTimer = timer }
    }

    public func stopKeepalive() {
        lock.withLock {
            keepaliveTimer?.cancel()
            keepaliveTimer = nil
        }
    }

    /// Cancel all client connections and stop the keepalive timer.
    public func shutdown() {
        stopKeepalive()
        let snapshot = lock.withLock {
            let s = clients
            clients.removeAll()
            return s
        }
        for (_, client) in snapshot {
            client.connection.cancel()
        }
    }

    // MARK: - Internals

    private func sendToAll(
        _ message: Data,
        matches: (@Sendable ([String: String]) -> Bool)?
    ) {
        let snapshot = lock.withLock { clients }
        var sent = 0
        for (id, client) in snapshot {
            if let matches, !matches(client.filters) { continue }
            sent += 1
            client.connection.send(content: message, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.removeClient(id: id) }
            })
        }
        logger.debug("SSE broadcast → \(sent)/\(snapshot.count) client(s)")
    }

    private static func formatMessage(eventType: String, data: String) -> Data {
        Data("event: \(eventType)\ndata: \(data)\n\n".utf8)
    }
}

// MARK: - Handshake

extension SSEBroadcaster {
    /// Wire bytes for the SSE upgrade handshake. HTTPServer writes these
    /// before handing the connection to the upgrade handler.
    public static let handshakeBytes: Data = Data("""
    HTTP/1.1 200 OK\r
    Content-Type: text/event-stream\r
    Cache-Control: no-cache\r
    Connection: keep-alive\r
    Access-Control-Allow-Origin: *\r
    X-Accel-Buffering: no\r
    \r

    """.utf8)
}
