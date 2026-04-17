import Testing
import Foundation
@testable import DaemonKit

// MARK: - Shared test helpers

private struct StubTask: DaemonTask {
    let name: String
    let schedule: TaskSchedule
    var executeBlock: @Sendable (TaskContext) async throws -> TaskResult = { _ in .empty }
    func execute(context: TaskContext) async throws -> TaskResult {
        try await executeBlock(context)
    }
}

private final class StubSource: TaskSource, @unchecked Sendable {
    var tasks: [any DaemonTask]
    var watchDirectory: URL? = nil
    init(tasks: [any DaemonTask]) { self.tasks = tasks }
    func discoverTasks() -> [any DaemonTask] { tasks }
    func shouldClearBlacklist(taskName: String) -> Bool { false }
}

private func makeContext(tmp: URL) -> DaemonContext {
    DaemonContext(
        crashTracker: CrashTracker(stateDir: tmp, subsystem: "endpoints.test"),
        analytics: RecordingAnalytics(),
        subsystem: "endpoints.test",
        supportDirectory: tmp
    )
}

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "endpoints-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func request(method: String, path: String, query: [String: String] = [:]) -> HTTPRequest {
    HTTPRequest(method: method, path: path, queryItems: query, headers: [:], body: nil)
}

private final class NopHandler: EventHandler, @unchecked Sendable {
    func start(context: DaemonContext) async throws {}
    func stop() async {}
    func handleTrigger() async throws {}
}

// MARK: - TimingStrategy endpoints

@Suite("TimingStrategy HTTP endpoints", .serialized)
struct TimingStrategyEndpointsTests {

    @Test("GET /strategy/{name}/snapshot returns JSON snapshot")
    func snapshotEndpoint() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = StubSource(tasks: [
            StubTask(name: "foo", schedule: .default),
            StubTask(name: "bar", schedule: .default)
        ])
        let strategy = TimingStrategy(name: "my-timer", taskSource: source)
        try await strategy.start(context: makeContext(tmp: tmp))
        defer { Task { await strategy.stop() } }

        let resp = try #require(await strategy.handle(request: request(method: "GET", path: "/strategy/my-timer/snapshot")))
        #expect(resp.status == 200)

        let decoded = try JSONDecoder.iso8601.decode(StrategySnapshot.self, from: resp.body)
        #expect(decoded.name == "my-timer")
        #expect(decoded.kind == "timing")
        #expect(decoded.workUnits.map(\.name).sorted() == ["bar", "foo"])
    }

    @Test("GET /jobs returns TimingJobSummary list")
    func jobsListEndpoint() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = StubSource(tasks: [
            StubTask(name: "alpha", schedule: .default),
            StubTask(name: "beta", schedule: .default)
        ])
        let strategy = TimingStrategy(taskSource: source)
        try await strategy.start(context: makeContext(tmp: tmp))
        defer { Task { await strategy.stop() } }

        let resp = try #require(await strategy.handle(request: request(method: "GET", path: "/jobs")))
        let summaries = try JSONDecoder.iso8601.decode([TimingJobSummary].self, from: resp.body)
        #expect(Set(summaries.map(\.name)) == Set(["alpha", "beta"]))
        #expect(summaries.allSatisfy { $0.state == "idle" || $0.state == "running" })
    }

    @Test("GET /jobs/{name} returns a single summary")
    func jobDetailEndpoint() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = StubSource(tasks: [StubTask(name: "specific", schedule: .default)])
        let strategy = TimingStrategy(taskSource: source)
        try await strategy.start(context: makeContext(tmp: tmp))
        defer { Task { await strategy.stop() } }

        let resp = try #require(await strategy.handle(request: request(method: "GET", path: "/jobs/specific")))
        let summary = try JSONDecoder.iso8601.decode(TimingJobSummary.self, from: resp.body)
        #expect(summary.name == "specific")
    }

    @Test("GET /jobs/{unknown} returns 404")
    func unknownJobReturns404() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = StubSource(tasks: [])
        let strategy = TimingStrategy(taskSource: source)
        try await strategy.start(context: makeContext(tmp: tmp))
        defer { Task { await strategy.stop() } }

        let resp = try #require(await strategy.handle(request: request(method: "GET", path: "/jobs/nothere")))
        #expect(resp.status == 404)
    }

    @Test("unrelated path returns nil")
    func unrelatedPathReturnsNil() async {
        let strategy = TimingStrategy(taskSource: StubSource(tasks: []))
        let resp = await strategy.handle(request: request(method: "GET", path: "/sessions"))
        #expect(resp == nil)
    }

    @Test("non-GET method returns nil")
    func nonGETReturnsNil() async {
        let strategy = TimingStrategy(taskSource: StubSource(tasks: []))
        let resp = await strategy.handle(request: request(method: "POST", path: "/jobs"))
        #expect(resp == nil)
    }
}

// MARK: - EventStrategy endpoints

@Suite("EventStrategy HTTP endpoints", .serialized)
struct EventStrategyEndpointsTests {

    @Test("GET /strategy/{name}/snapshot returns JSON snapshot")
    func snapshotEndpoint() async throws {
        let handler = NopHandler()
        let trigger = Trigger.custom(CustomTrigger(start: { _ in }, stop: {}))
        let strategy = EventStrategy(name: "ingest", trigger: trigger, handler: handler)

        let resp = try #require(await strategy.handle(request: request(method: "GET", path: "/strategy/ingest/snapshot")))
        let decoded = try JSONDecoder.iso8601.decode(StrategySnapshot.self, from: resp.body)
        #expect(decoded.name == "ingest")
        #expect(decoded.kind == "event")
    }

    @Test("GET /events/stream returns sseUpgrade response when broadcaster is set")
    func streamEndpointWithBroadcaster() async {
        let broadcaster = SSEBroadcaster(subsystem: "event.test")
        let trigger = Trigger.custom(CustomTrigger(start: { _ in }, stop: {}))
        let strategy = EventStrategy(
            trigger: trigger,
            handler: NopHandler(),
            broadcaster: broadcaster
        )

        let resp = await strategy.handle(request: request(
            method: "GET",
            path: "/events/stream",
            query: ["session_id": "abc", "scope": "b"]
        ))
        #expect(resp != nil)
        if case .sseUpgrade(let filters) = resp?.kind {
            #expect(filters["session_id"] == "abc")
            #expect(filters["scope"] == "b")
        } else {
            Issue.record("expected sseUpgrade kind")
        }
    }

    @Test("GET /events/stream returns nil when broadcaster is not set")
    func streamEndpointWithoutBroadcaster() async {
        let trigger = Trigger.custom(CustomTrigger(start: { _ in }, stop: {}))
        let strategy = EventStrategy(trigger: trigger, handler: NopHandler())

        let resp = await strategy.handle(request: request(method: "GET", path: "/events/stream"))
        #expect(resp == nil)
    }

    @Test("unrelated path returns nil")
    func unrelatedPathReturnsNil() async {
        let trigger = Trigger.custom(CustomTrigger(start: { _ in }, stop: {}))
        let strategy = EventStrategy(trigger: trigger, handler: NopHandler())
        let resp = await strategy.handle(request: request(method: "GET", path: "/jobs"))
        #expect(resp == nil)
    }
}

// MARK: - CompositeStrategy endpoints

@Suite("CompositeStrategy HTTP endpoint composition", .serialized)
struct CompositeStrategyEndpointsTests {

    @Test("composite delegates to first child that handles the request")
    func compositeDelegates() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let timing = TimingStrategy(taskSource: StubSource(tasks: [
            StubTask(name: "t1", schedule: .default)
        ]))
        let evt = EventStrategy(
            trigger: .custom(CustomTrigger(start: { _ in }, stop: {})),
            handler: NopHandler()
        )
        let composite = CompositeStrategy(name: "root", [timing, evt])

        try await timing.start(context: makeContext(tmp: tmp))
        defer { Task { await timing.stop() } }

        // /jobs -> handled by TimingStrategy
        let jobsResp = try #require(await composite.handle(request: request(method: "GET", path: "/jobs")))
        #expect(jobsResp.status == 200)

        // /strategy/event/snapshot -> handled by EventStrategy
        let snapResp = try #require(await composite.handle(request: request(method: "GET", path: "/strategy/event/snapshot")))
        #expect(snapResp.status == 200)

        // /unknown -> nil
        let unknown = await composite.handle(request: request(method: "GET", path: "/unknown"))
        #expect(unknown == nil)
    }
}

// MARK: - DaemonHealthRouter

@Suite("DaemonHealthRouter", .serialized)
struct DaemonHealthRouterTests {

    @Test("GET /health returns HealthStatus with strategy snapshot")
    func healthEndpointReturnsSnapshot() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let strategy = TimingStrategy(name: "tasks", taskSource: StubSource(tasks: [
            StubTask(name: "one", schedule: .default)
        ]))
        try await strategy.start(context: makeContext(tmp: tmp))
        defer { Task { await strategy.stop() } }

        let router = DaemonHealthRouter(
            strategy: strategy,
            version: "9.9.9",
            startDate: Date(timeIntervalSinceNow: -10)
        )
        let resp = await router.handle(request: request(method: "GET", path: "/health"))
        #expect(resp.status == 200)

        let health = try JSONDecoder.iso8601.decode(HealthStatus.self, from: resp.body)
        #expect(health.status == "ok")
        #expect(health.version == "9.9.9")
        #expect(health.uptimeSeconds >= 10)
        #expect(health.strategy.name == "tasks")
        #expect(health.strategy.workUnits.map(\.name) == ["one"])
    }

    @Test("delegates to strategy endpoints for known paths")
    func delegatesToStrategy() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let strategy = TimingStrategy(taskSource: StubSource(tasks: [
            StubTask(name: "x", schedule: .default)
        ]))
        try await strategy.start(context: makeContext(tmp: tmp))
        defer { Task { await strategy.stop() } }

        let router = DaemonHealthRouter(strategy: strategy, version: "1.0", startDate: Date())
        let resp = await router.handle(request: request(method: "GET", path: "/jobs"))
        #expect(resp.status == 200)

        let summaries = try JSONDecoder.iso8601.decode([TimingJobSummary].self, from: resp.body)
        #expect(summaries.count == 1)
    }

    @Test("falls back to extraEndpoints before 404")
    func extraEndpointsFallback() async throws {
        let extra = StubEndpoint(path: "/hello", body: "world")
        let strategy = TimingStrategy(taskSource: StubSource(tasks: []))
        let router = DaemonHealthRouter(
            strategy: strategy,
            version: "1.0",
            startDate: Date(),
            extraEndpoints: [extra]
        )

        let resp = await router.handle(request: request(method: "GET", path: "/hello"))
        #expect(resp.status == 200)
        #expect(String(data: resp.body, encoding: .utf8)?.contains("world") == true)
    }

    @Test("unknown path returns 404")
    func unknown404() async {
        let strategy = TimingStrategy(taskSource: StubSource(tasks: []))
        let router = DaemonHealthRouter(strategy: strategy, version: "1.0", startDate: Date())
        let resp = await router.handle(request: request(method: "GET", path: "/no"))
        #expect(resp.status == 404)
    }
}

// MARK: - Small helpers

private struct StubEndpoint: StrategyHTTPEndpoints {
    let path: String
    let body: String

    func handle(request: HTTPRequest) async -> HTTPResponse? {
        guard request.path == path else { return nil }
        return .json(["message": body])
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
