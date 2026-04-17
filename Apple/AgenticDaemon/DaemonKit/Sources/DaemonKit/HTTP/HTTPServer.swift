import Foundation
import Network
import os

/// A minimal HTTP/1.1 server that listens on localhost and dispatches
/// requests to a ``DaemonHTTPRouter``. Supports Server-Sent Events
/// upgrades when given an `sseUpgradeHandler`.
///
/// Uses `NWListener` from Network.framework. Binds to 127.0.0.1 only.
/// No TLS. Normal responses close the connection after the body is written;
/// SSE-upgrade responses keep the connection open and hand it off to the
/// supplied handler.
public final class HTTPServer: @unchecked Sendable {
    /// Signature for an SSE upgrade handler. Called after HTTPServer writes
    /// the standard SSE handshake bytes. The handler owns the connection
    /// lifecycle from this point forward — typically it hands the connection
    /// to an ``SSEBroadcaster``.
    public typealias SSEUpgradeHandler = @Sendable (
        _ connection: NWConnection,
        _ request: HTTPRequest,
        _ filters: [String: String]
    ) -> Void

    private let logger: Logger
    private let router: any DaemonHTTPRouter
    private let sseUpgradeHandler: SSEUpgradeHandler?
    private var listener: NWListener?
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "DaemonKit.HTTPServer", qos: .utility)

    /// The actual port the server is listening on. Valid after `startAndWait()`.
    public private(set) var actualPort: UInt16 = 0
    private let readySemaphore = DispatchSemaphore(value: 0)

    public init(
        port: UInt16,
        router: any DaemonHTTPRouter,
        subsystem: String,
        sseUpgradeHandler: SSEUpgradeHandler? = nil
    ) {
        self.requestedPort = port
        self.router = router
        self.sseUpgradeHandler = sseUpgradeHandler
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
                self.dispatch(response: response, request: request, connection: connection)
            }
        }
    }

    private func dispatch(response: HTTPResponse, request: HTTPRequest, connection: NWConnection) {
        switch response.kind {
        case .immediate:
            sendAndClose(response, on: connection)
        case .sseUpgrade(let filters):
            performSSEUpgrade(filters: filters, request: request, connection: connection)
        }
    }

    private func sendAndClose(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - SSE upgrade

    private func performSSEUpgrade(
        filters: [String: String],
        request: HTTPRequest,
        connection: NWConnection
    ) {
        guard let upgrade = sseUpgradeHandler else {
            logger.warning("SSE upgrade requested but no handler configured")
            sendAndClose(.error("SSE not configured", status: 501), on: connection)
            return
        }

        connection.send(
            content: SSEBroadcaster.handshakeBytes,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.debug("SSE handshake send error: \(error)")
                    connection.cancel()
                    return
                }
                upgrade(connection, request, filters)
            }
        )
    }
}
