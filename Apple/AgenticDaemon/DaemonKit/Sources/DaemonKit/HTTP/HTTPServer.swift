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
