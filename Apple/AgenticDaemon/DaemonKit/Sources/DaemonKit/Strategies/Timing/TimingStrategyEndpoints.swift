import Foundation

/// HTTP endpoints that any ``TimingStrategy`` exposes "for free":
///
/// - `GET /strategy/{name}/snapshot` — JSON `StrategySnapshot`
/// - `GET /jobs` — array of work unit summaries
/// - `GET /jobs/{taskName}` — single work unit summary
///
/// A daemon that wants the rich scheduler metadata (e.g. agentic-daemon's
/// `JobConfig`) should render its own `/jobs` endpoint and let this one
/// handle whatever it doesn't. Paths this doesn't own return `nil`.
extension TimingStrategy: StrategyHTTPEndpoints {
    public func handle(request: HTTPRequest) async -> HTTPResponse? {
        guard request.method == "GET" else { return nil }

        let path = request.path
        let snapshotPath = "/strategy/\(name)/snapshot"
        if path == snapshotPath {
            return .json(await snapshot())
        }

        if path == "/jobs" {
            let snap = await snapshot()
            let summaries = snap.workUnits.map(TimingJobSummary.init(unit:))
            return .json(summaries)
        }

        if path.hasPrefix("/jobs/") {
            let taskName = String(path.dropFirst("/jobs/".count))
            guard !taskName.isEmpty, !taskName.contains("/") else { return nil }
            let snap = await snapshot()
            guard let unit = snap.workUnits.first(where: { $0.name == taskName }) else {
                return .notFound("Unknown task: \(taskName)")
            }
            return .json(TimingJobSummary(unit: unit))
        }

        return nil
    }
}

/// Wire shape of a single timing work unit in `/jobs` responses.
/// Flat, snake-case friendly, no JobConfig (keep domain-specific config in
/// the client daemon's own endpoint).
public struct TimingJobSummary: Codable, Sendable {
    public let name: String
    public let state: String
    public let nextActivation: Date?
    public let consecutiveFailures: Int
    public let isBlacklisted: Bool

    public init(unit: WorkUnitSnapshot) {
        self.name = unit.name
        self.state = unit.state.rawValue
        self.nextActivation = unit.nextActivation
        self.consecutiveFailures = unit.consecutiveFailures
        self.isBlacklisted = unit.isBlacklisted
    }
}
