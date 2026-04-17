import Foundation

/// A strategy that wants to expose HTTP endpoints conforms to this.
///
/// The contract is a fallback: return a response if the request's path/method
/// is one the strategy owns, otherwise return `nil` so the caller can try
/// another handler. Client routers typically try their own domain-specific
/// routes first, then fall back through their strategies' endpoints, then
/// finally return 404.
///
///     struct MyRouter: DaemonHTTPRouter {
///         let strategy: CompositeStrategy
///         func handle(request: HTTPRequest) async -> HTTPResponse {
///             if request.path == "/sessions" { return ... }   // domain-specific
///             if let r = await strategy.handle(request: request) { return r }
///             return .notFound()
///         }
///     }
public protocol StrategyHTTPEndpoints: Sendable {
    /// Handle an HTTP request, or return nil if this strategy doesn't own it.
    func handle(request: HTTPRequest) async -> HTTPResponse?
}

// MARK: - CompositeStrategy endpoint composition

extension CompositeStrategy: StrategyHTTPEndpoints {
    /// Delegates to each child that conforms to `StrategyHTTPEndpoints`.
    /// Returns the first non-nil response. Order matches declaration order.
    public func handle(request: HTTPRequest) async -> HTTPResponse? {
        for child in children {
            if let endpoint = child as? any StrategyHTTPEndpoints,
               let response = await endpoint.handle(request: request) {
                return response
            }
        }
        return nil
    }
}
