import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("Scheduler", .serialized)
struct SchedulerTests {

    @Test("syncJobs adds new enabled jobs")
    func addsEnabledJobs() async {
        let tmpDir = makeTempDir(prefix: "sched")
        createJobDir(in: tmpDir, name: "job-a", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "job-a")
        let scheduler = Scheduler(buildDir: findBuildDir())

        await scheduler.syncJobs(discovered: [descriptor])

        let count = await scheduler.jobCount
        let names = await scheduler.jobNames
        #expect(count == 1)
        #expect(names.contains("job-a"))
        cleanupTempDir(tmpDir)
    }

    @Test("syncJobs skips disabled jobs")
    func skipsDisabledJobs() async {
        let tmpDir = makeTempDir(prefix: "sched")
        createJobDir(in: tmpDir, name: "disabled", swiftSource: validJobSource())
        let config = JobConfig(enabled: false)
        let descriptor = makeDescriptor(in: tmpDir, name: "disabled", config: config)
        let scheduler = Scheduler(buildDir: findBuildDir())

        await scheduler.syncJobs(discovered: [descriptor])

        let empty = await scheduler.isEmpty
        #expect(empty)
        cleanupTempDir(tmpDir)
    }

    @Test("syncJobs removes jobs no longer discovered")
    func removesDeletedJobs() async {
        let tmpDir = makeTempDir(prefix: "sched")
        createJobDir(in: tmpDir, name: "ephemeral", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "ephemeral")
        let scheduler = Scheduler(buildDir: findBuildDir())

        await scheduler.syncJobs(discovered: [descriptor])
        let count1 = await scheduler.jobCount
        #expect(count1 == 1)

        await scheduler.syncJobs(discovered: [])
        let empty = await scheduler.isEmpty
        #expect(empty)
        cleanupTempDir(tmpDir)
    }

    @Test("tick dispatches jobs whose nextRun is past")
    func dispatchesPastJobs() async {
        let tmpDir = makeTempDir(prefix: "sched")
        createJobDir(in: tmpDir, name: "ready", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "ready")
        let scheduler = Scheduler(buildDir: findBuildDir())

        await scheduler.syncJobs(discovered: [descriptor])
        await scheduler.tick()

        try? await Task.sleep(for: .seconds(1))

        let count = await scheduler.jobCount
        #expect(count == 1)
        cleanupTempDir(tmpDir)
    }

    @Test("triggerJob sets nextRun to now for a known job")
    func triggerJobSetsNextRunToNow() async throws {
        let tmpDir = makeTempDir(prefix: "sched-trigger")
        createJobDir(in: tmpDir, name: "job-trigger", swiftSource: validJobSource())
        let config = JobConfig(intervalSeconds: 3600)
        let descriptor = makeDescriptor(in: tmpDir, name: "job-trigger", config: config)
        let scheduler = Scheduler(buildDir: findBuildDir())

        await scheduler.syncJobs(discovered: [descriptor])

        try await Task.sleep(for: .milliseconds(20))

        await scheduler.triggerJob(name: "job-trigger")

        let job = await scheduler.job(named: "job-trigger")
        let nextRun = try #require(job?.nextRun)
        #expect(nextRun.timeIntervalSinceNow <= 0.1)

        cleanupTempDir(tmpDir)
    }

    @Test("triggerJob is a no-op for unknown job")
    func triggerJobUnknownIsNoOp() async {
        let scheduler = Scheduler(buildDir: findBuildDir())
        await scheduler.triggerJob(name: "does-not-exist")
        let empty = await scheduler.isEmpty
        #expect(empty)
    }
}
