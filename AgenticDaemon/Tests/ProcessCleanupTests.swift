import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("ProcessCleanup", .serialized)
struct ProcessCleanupTests {

    @Test("Running job processes are terminated on shutdown")
    func terminatesOnShutdown() async throws {
        let tmpDir = makeTempDir(prefix: "cleanup")
        let source = "import Foundation\nThread.sleep(forTimeInterval: 60)\n"
        createJobDir(in: tmpDir, name: "long-running", swiftSource: source)
        let config = JobConfig(intervalSeconds: 9999, timeout: 60)
        let descriptor = makeDescriptor(in: tmpDir, name: "long-running", config: config)

        let compiler = SwiftCompiler()
        try compiler.compile(job: descriptor)

        let scheduler = Scheduler()
        await scheduler.syncJobs(discovered: [descriptor])

        await scheduler.tick()
        try await Task.sleep(for: .milliseconds(500))

        let job = await scheduler.job(named: "long-running")
        #expect(job?.isRunning == true)

        let start = Date.now
        scheduler.terminateAllRunning(gracePeriod: 2.0)
        let elapsed = Date.now.timeIntervalSince(start)

        #expect(elapsed < 10)
        cleanupTempDir(tmpDir)
    }
}
