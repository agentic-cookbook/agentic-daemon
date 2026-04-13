import Foundation
import Network
import os

public final class HTTPServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.agentic-cookbook.daemon", category: "HTTPServer")
    private let router: HTTPRouter
    private var listener: NWListener?
    private let port: UInt16

    public init(router: HTTPRouter, port: UInt16 = 22846) {
        self.router = router
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        l.start(queue: .global(qos: .utility))
        listener = l
        logger.info("HTTP server listening on port \(self.port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel()
                return
            }
            guard let request = HTTPRequestParser.parse(data) else {
                self.send(.notFound(), to: connection)
                return
            }
            Task {
                let response = await self.router.handle(
                    method: request.method,
                    path: request.path,
                    body: request.body
                )
                self.send(response, to: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, to connection: NWConnection) {
        let header = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n" +
            "Content-Type: \(response.contentType)\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 404: "Not Found"
        default:  "Error"
        }
    }
}

// MARK: - Request parser

struct ParsedRequest {
    let method: String
    let path: String
    let body: Data?
}

enum HTTPRequestParser {
    static func parse(_ data: Data) -> ParsedRequest? {
        guard let str = String(data: data, encoding: .utf8),
              let headerEnd = str.range(of: "\r\n\r\n") else { return nil }
        let headerSection = String(str[str.startIndex..<headerEnd.lowerBound])
        guard let requestLine = headerSection.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]
        return ParsedRequest(method: parts[0], path: path, body: nil)
    }
}
