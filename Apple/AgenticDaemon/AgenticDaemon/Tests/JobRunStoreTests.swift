import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite struct JobRunStoreTests {
    func makeStore() throws -> JobRunStore {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "runs-\(UUID().uuidString).db")
        return try JobRunStore(databaseURL: tmp)
    }

    @Test func recordAndQuery() throws {
        let store = try makeStore()
        let run = JobRun(
            jobName: "test-job",
            startedAt: Date(timeIntervalSinceNow: -5),
            endedAt: Date(),
            durationSeconds: 5.0,
            success: true
        )
        store.record(run)
        // give async write time to complete
        Thread.sleep(forTimeInterval: 0.05)
        let runs = store.runs(for: "test-job", limit: 10)
        #expect(runs.count == 1)
        #expect(runs[0].jobName == "test-job")
        #expect(runs[0].success == true)
    }

    @Test func queryReturnsNewestFirst() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSinceNow: -100)
        for i in 0..<5 {
            let run = JobRun(
                jobName: "j",
                startedAt: base.addingTimeInterval(Double(i * 10)),
                endedAt: base.addingTimeInterval(Double(i * 10 + 1)),
                durationSeconds: 1.0,
                success: true
            )
            store.record(run)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let runs = store.runs(for: "j", limit: 10)
        #expect(runs.count == 5)
        #expect(runs[0].startedAt >= runs[1].startedAt)
    }

    @Test func limitIsRespected() throws {
        let store = try makeStore()
        for _ in 0..<20 {
            let run = JobRun(
                jobName: "j",
                startedAt: Date(timeIntervalSinceNow: -1),
                endedAt: Date(),
                durationSeconds: 1.0,
                success: true
            )
            store.record(run)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let runs = store.runs(for: "j", limit: 5)
        #expect(runs.count == 5)
    }

    @Test func recentRunsAcrossJobs() throws {
        let store = try makeStore()
        for name in ["a", "b", "c"] {
            let run = JobRun(
                jobName: name,
                startedAt: Date(timeIntervalSinceNow: -1),
                endedAt: Date(),
                durationSeconds: 1.0,
                success: true
            )
            store.record(run)
        }
        Thread.sleep(forTimeInterval: 0.05)
        let runs = store.recentRuns(limit: 10)
        #expect(runs.count == 3)
    }

    @Test func cleanupRemovesOldRuns() throws {
        let store = try makeStore()
        let old = JobRun(
            jobName: "j",
            startedAt: Date(timeIntervalSinceNow: -31 * 86400),
            endedAt: Date(timeIntervalSinceNow: -31 * 86400 + 1),
            durationSeconds: 1.0,
            success: true
        )
        let recent = JobRun(
            jobName: "j",
            startedAt: Date(timeIntervalSinceNow: -1),
            endedAt: Date(),
            durationSeconds: 1.0,
            success: true
        )
        store.record(old)
        store.record(recent)
        Thread.sleep(forTimeInterval: 0.05)
        store.cleanup(retentionDays: 30)
        Thread.sleep(forTimeInterval: 0.05)
        let runs = store.runs(for: "j", limit: 10)
        #expect(runs.count == 1)
        #expect(runs[0].success == true)
    }
}
