import Testing
import Foundation
@testable import DaemonKit

@Suite("DaemonHTTPClient", .serialized)
struct DaemonHTTPClientTests {

    struct HealthPayload: Codable { let status: String; let uptime: Double }

    /// Router that returns a known JSON payload for /health.
    struct HealthRouter: DaemonHTTPRouter {
        func handle(request: HTTPRequest) async -> HTTPResponse {
            if request.path == "/health" {
                return .json(HealthPayload(status: "ok", uptime: 42.0))
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
