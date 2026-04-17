import Foundation

/// HTTP endpoints that an ``EventStrategy`` exposes:
///
/// - `GET /strategy/{name}/snapshot` — JSON `StrategySnapshot`
/// - `GET /events/stream` — SSE upgrade (only when the strategy was
///   constructed with a non-nil `broadcaster`; otherwise omitted so the
///   client's own router can own the path if it needs to)
///
/// Query parameters passed to `/events/stream` become the SSE client's
/// `filters` dictionary in the broadcaster — e.g. `?session_id=abc` lands
/// as `filters["session_id"] = "abc"`.
extension EventStrategy: StrategyHTTPEndpoints {
    public func handle(request: HTTPRequest) async -> HTTPResponse? {
        guard request.method == "GET" else { return nil }

        let snapshotPath = "/strategy/\(name)/snapshot"
        if request.path == snapshotPath {
            return .json(await snapshot())
        }

        if request.path == "/events/stream", broadcaster != nil {
            return .sseUpgrade(filters: request.queryItems)
        }

        return nil
    }
}
