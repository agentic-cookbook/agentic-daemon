import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite struct HTTPRouterTests {
    func makeRouter() throws -> (HTTPRouter, JobRunStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "runs-\(UUID().uuidString).db")
        let store = try JobRunStore(databaseURL: tmp)
        let stateDir = FileManager.default.temporaryDirectory
            .appending(path: "state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let tracker = CrashTracker(stateDir: stateDir)
        let router = HTTPRouter(
            scheduler: Scheduler(buildDir: FileManager.default.temporaryDirectory),
            jobRunStore: store,
            crashTracker: tracker,
            startTime: Date()
        )
        return (router, store)
    }

    @Test func healthReturnsOK() async throws {
        let (router, _) = try makeRouter()
        let response = await router.handle(method: "GET", path: "/health", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(json?["status"] as? String == "ok")
    }

    @Test func unknownPathReturns404() async throws {
        let (router, _) = try makeRouter()
        let response = await router.handle(method: "GET", path: "/nonexistent", body: nil)
        #expect(response.status == 404)
    }

    @Test func jobsReturnsArray() async throws {
        let (router, _) = try makeRouter()
        let response = await router.handle(method: "GET", path: "/jobs", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        #expect(json != nil)
    }

    @Test func runsEndpointReturnsArray() async throws {
        let (router, store) = try makeRouter()
        let run = JobRun(
            jobName: "my-job",
            startedAt: Date(timeIntervalSinceNow: -5),
            endedAt: Date(),
            durationSeconds: 5.0,
            success: true
        )
        store.record(run)
        try await Task.sleep(for: .milliseconds(50))
        let response = await router.handle(method: "GET", path: "/jobs/my-job/runs", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        #expect(json != nil)
    }

    @Test func recentRunsEndpoint() async throws {
        let (router, store) = try makeRouter()
        for name in ["alpha", "beta"] {
            store.record(JobRun(
                jobName: name,
                startedAt: Date(timeIntervalSinceNow: -1),
                endedAt: Date(),
                durationSeconds: 1.0,
                success: true
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        let response = await router.handle(method: "GET", path: "/runs", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        #expect((json?.count ?? 0) >= 2)
    }
}
