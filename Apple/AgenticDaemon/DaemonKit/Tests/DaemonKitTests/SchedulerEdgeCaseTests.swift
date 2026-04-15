import Testing
import Foundation
@testable import DaemonKit

// MARK: - Test doubles

private struct StubTask: DaemonTask {
    let name: String
    let schedule: TaskSchedule
    var executeBlock: @Sendable (TaskContext) async throws -> TaskResult = { _ in .empty }

    func execute(context: TaskContext) async throws -> TaskResult {
        try await executeBlock(context)
    }
}

private struct StubSource: TaskSource {
    var tasks: [any DaemonTask]
    var watchDirectory: URL? = nil
    var shouldClearBlacklistHandler: @Sendable (String) -> Bool = { _ in false }

    func discoverTasks() -> [any DaemonTask] { tasks }
    func shouldClearBlacklist(taskName: String) -> Bool { shouldClearBlacklistHandler(taskName) }
}

private func makeScheduler() -> (Scheduler, CrashTracker) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appending(path: "sched-edge-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let tracker = CrashTracker(stateDir: tmpDir, subsystem: "test")
    let analytics = StubAnalytics()
    let scheduler = Scheduler(crashTracker: tracker, analytics: analytics, subsystem: "test")
    return (scheduler, tracker)
}

private final class StubAnalytics: AnalyticsProvider, @unchecked Sendable {
    private var _events: [AnalyticsEvent] = []
    private let lock = NSLock()
    var events: [AnalyticsEvent] { lock.withLock { _events } }
    func track(_ event: AnalyticsEvent) { lock.withLock { _events.append(event) } }
}

// MARK: - Tests

@Suite("Scheduler edge cases", .serialized)
struct SchedulerEdgeCaseTests {

    @Test("recoverFromCrash blacklists the crashed task")
    func recoverFromCrashBlacklists() async {
        let (scheduler, tracker) = makeScheduler()
        tracker.markRunning(taskName: "crasher")

        // Simulate daemon restart — don't clear running, then recover
        await scheduler.recoverFromCrash()

        #expect(tracker.isBlacklisted(taskName: "crasher"))
    }

    @Test("recoverFromCrash is no-op when no crash detected")
    func recoverFromCrashNoOp() async {
        let (scheduler, tracker) = makeScheduler()

        await scheduler.recoverFromCrash()

        #expect(!tracker.isBlacklisted(taskName: "anything"))
    }

    @Test("syncTasks skips blacklisted tasks")
    func syncSkipsBlacklisted() async {
        let (scheduler, tracker) = makeScheduler()
        tracker.blacklist(taskName: "bad-task")

        let task = StubTask(name: "bad-task", schedule: .default)
        let source = StubSource(tasks: [task])
        await scheduler.syncTasks(from: source)

        let empty = await scheduler.isEmpty
        #expect(empty)
    }

    @Test("syncTasks clears blacklist when shouldClearBlacklist returns true")
    func syncClearsBlacklistWhenSourceChanged() async {
        let (scheduler, tracker) = makeScheduler()
        tracker.blacklist(taskName: "fixed-task")

        let task = StubTask(name: "fixed-task", schedule: .default)
        let source = StubSource(tasks: [task], shouldClearBlacklistHandler: { _ in true })
        await scheduler.syncTasks(from: source)

        let count = await scheduler.taskCount
        #expect(count == 1)
        #expect(!tracker.isBlacklisted(taskName: "fixed-task"))
    }

    @Test("syncTasks updates existing task objects on re-sync")
    func syncUpdatesExistingTasks() async {
        let (scheduler, _) = makeScheduler()
        let task1 = StubTask(name: "evolving", schedule: TaskSchedule(intervalSeconds: 60))
        let source1 = StubSource(tasks: [task1])
        await scheduler.syncTasks(from: source1)

        let task2 = StubTask(name: "evolving", schedule: TaskSchedule(intervalSeconds: 120))
        let source2 = StubSource(tasks: [task2])
        await scheduler.syncTasks(from: source2)

        let scheduled = await scheduler.scheduledTask(named: "evolving")
        #expect(scheduled?.task.schedule.intervalSeconds == 120)
    }

    @Test("triggerTask sets pendingRunReason to .triggered")
    func triggerSetsReason() async {
        let (scheduler, _) = makeScheduler()
        let task = StubTask(name: "t", schedule: TaskSchedule(intervalSeconds: 3600))
        let source = StubSource(tasks: [task])
        await scheduler.syncTasks(from: source)

        await scheduler.triggerTask(name: "t")

        let scheduled = await scheduler.scheduledTask(named: "t")
        #expect(scheduled?.pendingRunReason == .triggered)
    }

    @Test("task execution resets consecutiveFailures on success")
    func successResetsFailures() async {
        let (scheduler, _) = makeScheduler()
        let task = StubTask(name: "ok", schedule: TaskSchedule(intervalSeconds: 10))
        let source = StubSource(tasks: [task])
        await scheduler.syncTasks(from: source)

        await scheduler.tick()
        try? await Task.sleep(for: .milliseconds(200))

        let scheduled = await scheduler.scheduledTask(named: "ok")
        #expect(scheduled?.consecutiveFailures == 0)
        #expect(scheduled?.isRunning == false)
    }

    @Test("task execution increments consecutiveFailures on error")
    func failureIncrementsCount() async {
        let (scheduler, _) = makeScheduler()
        let task = StubTask(name: "fail", schedule: TaskSchedule(intervalSeconds: 10)) { _ in
            throw NSError(domain: "test", code: 1)
        }
        let source = StubSource(tasks: [task])
        await scheduler.syncTasks(from: source)

        await scheduler.tick()
        try? await Task.sleep(for: .milliseconds(200))

        let scheduled = await scheduler.scheduledTask(named: "fail")
        #expect(scheduled?.consecutiveFailures == 1)
    }

    @Test("task can trigger another task via result")
    func taskTriggersAnother() async {
        let (scheduler, _) = makeScheduler()
        let taskA = StubTask(name: "a", schedule: TaskSchedule(intervalSeconds: 10)) { _ in
            TaskResult(trigger: ["b"])
        }
        let taskB = StubTask(name: "b", schedule: TaskSchedule(intervalSeconds: 3600))
        let source = StubSource(tasks: [taskA, taskB])
        await scheduler.syncTasks(from: source)

        // Give task B a far-future nextRun so it won't run on its own
        try? await Task.sleep(for: .milliseconds(10))

        // Run task A (which triggers B)
        await scheduler.tick()

        // After A completes, B should have nextRun set to ~now.
        // Poll rather than sleep-once, so this doesn't flake under load.
        var b = await scheduler.scheduledTask(named: "b")
        for _ in 0..<40 where (b?.nextRun.timeIntervalSinceNow ?? 999) > 1.0 {
            try? await Task.sleep(for: .milliseconds(50))
            b = await scheduler.scheduledTask(named: "b")
        }
        #expect(b?.nextRun.timeIntervalSinceNow ?? 999 < 1.0)
    }

    @Test("task can disable itself via result")
    func taskDisablesItself() async {
        let (scheduler, _) = makeScheduler()
        let task = StubTask(name: "self-destruct", schedule: TaskSchedule(intervalSeconds: 10)) { _ in
            TaskResult(enabled: false)
        }
        let source = StubSource(tasks: [task])
        await scheduler.syncTasks(from: source)

        await scheduler.tick()
        try? await Task.sleep(for: .milliseconds(200))

        let empty = await scheduler.isEmpty
        #expect(empty)
    }

    @Test("task can override next run interval via result")
    func taskOverridesNextRun() async {
        let (scheduler, _) = makeScheduler()
        let task = StubTask(name: "custom-interval", schedule: TaskSchedule(intervalSeconds: 10)) { _ in
            TaskResult(nextRunSeconds: 999)
        }
        let source = StubSource(tasks: [task])
        await scheduler.syncTasks(from: source)

        await scheduler.tick()
        try? await Task.sleep(for: .milliseconds(200))

        let scheduled = await scheduler.scheduledTask(named: "custom-interval")
        // nextRun should be ~999s from now, not ~10s
        let secsUntilNext = scheduled?.nextRun.timeIntervalSinceNow ?? 0
        #expect(secsUntilNext > 900)
    }
}
