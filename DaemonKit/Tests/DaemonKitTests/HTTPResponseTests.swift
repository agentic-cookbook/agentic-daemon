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
