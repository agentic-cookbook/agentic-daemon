import Foundation

/// Turnkey `DaemonHTTPRouter` for daemons that don't need domain-specific
/// routes beyond health + strategy introspection.
///
/// Mounts:
/// - `GET /health` — `HealthStatus` JSON (status, uptime, version, strategy snapshot)
/// - Whatever routes the supplied strategies expose via ``StrategyHTTPEndpoints``
///
/// Daemons with richer surfaces should compose instead of using this router:
///
///     struct MyRouter: DaemonHTTPRouter {
///         let helper: DaemonHealthRouter
///         let timingStrategy: TimingStrategy
///         func handle(request: HTTPRequest) async -> HTTPResponse {
///             if request.path == "/sessions" { return await renderSessions() }
///             return await helper.handle(request: request)
///         }
///     }
public struct DaemonHealthRouter: DaemonHTTPRouter {
    public let strategy: any DaemonStrategy
    public let version: String
    public let startDate: Date
    public let extraEndpoints: [any StrategyHTTPEndpoints]

    public init(
        strategy: any DaemonStrategy,
        version: String = "1.0.0",
        startDate: Date,
        extraEndpoints: [any StrategyHTTPEndpoints] = []
    ) {
        self.strategy = strategy
        self.version = version
        self.startDate = startDate
        self.extraEndpoints = extraEndpoints
    }

    public func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == "/health" {
            let snap = await strategy.snapshot()
            let status = HealthStatus(
                status: "ok",
                version: version,
                uptimeSeconds: Date.now.timeIntervalSince(startDate),
                strategy: snap
            )
            return .json(status)
        }

        if let endpoint = strategy as? any StrategyHTTPEndpoints,
           let response = await endpoint.handle(request: request) {
            return response
        }

        for endpoint in extraEndpoints {
            if let response = await endpoint.handle(request: request) {
                return response
            }
        }

        return .notFound()
    }
}

/// Wire shape of the `GET /health` response.
public struct HealthStatus: Codable, Sendable {
    public let status: String
    public let version: String
    public let uptimeSeconds: TimeInterval
    public let strategy: StrategySnapshot

    public init(status: String, version: String, uptimeSeconds: TimeInterval, strategy: StrategySnapshot) {
        self.status = status
        self.version = version
        self.uptimeSeconds = uptimeSeconds
        self.strategy = strategy
    }
}
