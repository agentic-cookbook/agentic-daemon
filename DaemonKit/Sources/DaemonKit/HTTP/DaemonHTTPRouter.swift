import Foundation

/// Protocol for routing HTTP requests. Clients implement this to define their
/// daemon's HTTP API endpoints.
public protocol DaemonHTTPRouter: Sendable {
    /// Handle an HTTP request and return a response.
    func handle(request: HTTPRequest) async -> HTTPResponse
}
