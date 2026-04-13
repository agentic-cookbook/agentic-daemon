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
