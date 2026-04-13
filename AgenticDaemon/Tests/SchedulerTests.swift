import Testing
import Foundation
@testable import AgenticDaemonLib

// MARK: - Test doubles

struct StubDaemonTask: DaemonTask {
    let name: String
    let schedule: TaskSchedule
    var executeBlock: @Sendable (TaskContext) async throws -> TaskResult = { _ in .empty }

    func execute(context: TaskContext) async throws -> TaskResult {
        try await executeBlock(context)
    }
}

struct StubTaskSource: TaskSource {
    var tasks: [any DaemonTask]
    var watchDirectory: URL? = nil
    var shouldClearBlacklistHandler: @Sendable (String) -> Bool = { _ in false }

    func discoverTasks() -> [any DaemonTask] { tasks }
    func shouldClearBlacklist(taskName: String) -> Bool { shouldClearBlacklistHandler(taskName) }
}

private func makeScheduler(stateDir: URL) -> (Scheduler, CrashTracker) {
    let tracker = CrashTracker(stateDir: stateDir, subsystem: "test")
    let analytics = MockAnalyticsProvider()
    let scheduler = Scheduler(crashTracker: tracker, analytics: analytics, subsystem: "test")
    return (scheduler, tracker)
}

@Suite("Scheduler", .serialized)
struct SchedulerTests {

    @Test("syncTasks adds new enabled tasks")
    func addsEnabledTasks() async {
        let tmpDir = makeTempDir(prefix: "sched")
        let (scheduler, _) = makeScheduler(stateDir: tmpDir)
        let task = StubDaemonTask(name: "task-a", schedule: .default)
        let source = StubTaskSource(tasks: [task])

        await scheduler.syncTasks(from: source)

        let count = await scheduler.taskCount
        let names = await scheduler.taskNames
        #expect(count == 1)
        #expect(names.contains("task-a"))
        cleanupTempDir(tmpDir)
    }

    @Test("syncTasks skips disabled tasks")
    func skipsDisabledTasks() async {
        let tmpDir = makeTempDir(prefix: "sched")
        let (scheduler, _) = makeScheduler(stateDir: tmpDir)
        let task = StubDaemonTask(name: "disabled", schedule: TaskSchedule(enabled: false))
        let source = StubTaskSource(tasks: [task])

        await scheduler.syncTasks(from: source)

        let empty = await scheduler.isEmpty
        #expect(empty)
        cleanupTempDir(tmpDir)
    }

    @Test("syncTasks removes tasks no longer discovered")
    func removesDeletedTasks() async {
        let tmpDir = makeTempDir(prefix: "sched")
        let (scheduler, _) = makeScheduler(stateDir: tmpDir)
        let task = StubDaemonTask(name: "ephemeral", schedule: .default)
        let source = StubTaskSource(tasks: [task])

        await scheduler.syncTasks(from: source)
        let count1 = await scheduler.taskCount
        #expect(count1 == 1)

        let emptySource = StubTaskSource(tasks: [])
        await scheduler.syncTasks(from: emptySource)
        let empty = await scheduler.isEmpty
        #expect(empty)
        cleanupTempDir(tmpDir)
    }

    @Test("tick dispatches tasks whose nextRun is past")
    func dispatchesPastTasks() async {
        let tmpDir = makeTempDir(prefix: "sched")
        let (scheduler, _) = makeScheduler(stateDir: tmpDir)
        let task = StubDaemonTask(name: "ready", schedule: .default)
        let source = StubTaskSource(tasks: [task])

        await scheduler.syncTasks(from: source)
        await scheduler.tick()

        try? await Task.sleep(for: .seconds(1))

        let count = await scheduler.taskCount
        #expect(count == 1)
        cleanupTempDir(tmpDir)
    }

    @Test("triggerTask sets nextRun to now for a known task")
    func triggerTaskSetsNextRunToNow() async throws {
        let tmpDir = makeTempDir(prefix: "sched-trigger")
        let (scheduler, _) = makeScheduler(stateDir: tmpDir)
        let task = StubDaemonTask(name: "task-trigger", schedule: TaskSchedule(intervalSeconds: 3600))
        let source = StubTaskSource(tasks: [task])

        await scheduler.syncTasks(from: source)

        try await Task.sleep(for: .milliseconds(20))

        await scheduler.triggerTask(name: "task-trigger")

        let scheduled = await scheduler.scheduledTask(named: "task-trigger")
        let nextRun = try #require(scheduled?.nextRun)
        #expect(nextRun.timeIntervalSinceNow <= 0.1)

        cleanupTempDir(tmpDir)
    }

    @Test("triggerTask is a no-op for unknown task")
    func triggerTaskUnknownIsNoOp() async {
        let tmpDir = makeTempDir(prefix: "sched")
        let (scheduler, _) = makeScheduler(stateDir: tmpDir)
        await scheduler.triggerTask(name: "does-not-exist")
        let empty = await scheduler.isEmpty
        #expect(empty)
        cleanupTempDir(tmpDir)
    }
}
