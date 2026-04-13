import Foundation
import os

public actor Scheduler {
    private let logger: Logger
    private let analytics: any AnalyticsProvider
    private let crashTracker: CrashTracker
    private var scheduledTasks: [String: ScheduledTask] = [:]

    public struct ScheduledTask: Sendable {
        public var task: any DaemonTask
        public var nextRun: Date
        public var consecutiveFailures: Int = 0
        public var isRunning: Bool = false
        public var pendingRunReason: TaskContext.RunReason = .scheduled
    }

    public init(
        crashTracker: CrashTracker,
        analytics: any AnalyticsProvider,
        subsystem: String
    ) {
        self.logger = Logger(subsystem: subsystem, category: "Scheduler")
        self.crashTracker = crashTracker
        self.analytics = analytics
    }

    public func syncTasks(from taskSource: any TaskSource) {
        let discovered = taskSource.discoverTasks()
        let discoveredNames = Set(discovered.map(\.name))
        let currentNames = Set(scheduledTasks.keys)

        for task in discovered where !currentNames.contains(task.name) {
            guard task.schedule.enabled else {
                logger.info("Skipping disabled task: \(task.name)")
                continue
            }
            if crashTracker.isBlacklisted(taskName: task.name) {
                if taskSource.shouldClearBlacklist(taskName: task.name) {
                    logger.info("Source changed for blacklisted \(task.name), clearing blacklist")
                    crashTracker.clearBlacklist(taskName: task.name)
                } else {
                    logger.warning("Skipping blacklisted task: \(task.name)")
                    continue
                }
            }
            scheduledTasks[task.name] = ScheduledTask(task: task, nextRun: Date.now)
            logger.info("Added task: \(task.name) (interval: \(task.schedule.intervalSeconds)s)")
        }

        for name in currentNames.subtracting(discoveredNames) {
            scheduledTasks.removeValue(forKey: name)
            logger.info("Removed task: \(name)")
        }

        for task in discovered where currentNames.contains(task.name) {
            if crashTracker.isBlacklisted(taskName: task.name) && taskSource.shouldClearBlacklist(taskName: task.name) {
                logger.info("Source changed for blacklisted \(task.name), clearing blacklist")
                crashTracker.clearBlacklist(taskName: task.name)
            }
            scheduledTasks[task.name]?.task = task
        }
    }

    public func tick() {
        let now = Date.now
        var tasksToRun: [ScheduledTask] = []

        for (_, scheduled) in scheduledTasks where scheduled.nextRun <= now && !scheduled.isRunning {
            tasksToRun.append(scheduled)
        }
        for scheduled in tasksToRun {
            scheduledTasks[scheduled.task.name]?.isRunning = true
            scheduledTasks[scheduled.task.name]?.pendingRunReason = .scheduled
        }

        for scheduled in tasksToRun {
            let task = scheduled.task
            let failures = scheduled.consecutiveFailures
            let reason = scheduled.pendingRunReason
            Task.detached(priority: .utility) { [self] in
                await self.runTask(task: task, consecutiveFailures: failures, runReason: reason)
            }
        }
    }

    private func runTask(task: any DaemonTask, consecutiveFailures: Int, runReason: TaskContext.RunReason) async {
        let name = task.name
        analytics.track(.taskStarted(name: name))
        crashTracker.markRunning(taskName: name)
        let startTime = Date.now

        do {
            let context = TaskContext(
                taskName: name,
                consecutiveFailures: consecutiveFailures,
                runReason: runReason
            )
            let result = try await task.execute(context: context)
            let duration = Date.now.timeIntervalSince(startTime)

            crashTracker.clearRunning()
            analytics.track(.taskCompleted(name: name, durationSeconds: duration))

            if let message = result.message {
                logger.info("Task \(name): \(message)")
            }

            handleResult(result, for: name, failed: false)

        } catch {
            let duration = Date.now.timeIntervalSince(startTime)
            crashTracker.clearRunning()
            analytics.track(.taskFailed(name: name, durationSeconds: duration))
            logger.error("Task \(name) failed: \(error)")

            handleResult(nil, for: name, failed: true)
        }
    }

    private func handleResult(_ result: TaskResult?, for name: String, failed: Bool) {
        guard var entry = scheduledTasks[name] else { return }

        if failed {
            entry.consecutiveFailures += 1
        } else {
            entry.consecutiveFailures = 0
        }

        if let enabled = result?.enabled, !enabled {
            scheduledTasks.removeValue(forKey: name)
            logger.info("Task \(name) disabled itself")
            return
        }

        if let triggers = result?.trigger {
            for triggerName in triggers {
                if scheduledTasks[triggerName] != nil {
                    scheduledTasks[triggerName]?.nextRun = Date.now
                    logger.info("Task \(name) triggered \(triggerName)")
                } else {
                    logger.warning("Task \(name) tried to trigger unknown task: \(triggerName)")
                }
            }
        }

        if let nextRunAt = result?.nextRunAt {
            entry.nextRun = nextRunAt
        } else if let nextRunSeconds = result?.nextRunSeconds {
            entry.nextRun = Date.now.addingTimeInterval(nextRunSeconds)
        } else {
            entry.nextRun = Date.now.addingTimeInterval(backoffInterval(for: entry))
        }

        entry.isRunning = false
        scheduledTasks[name] = entry
    }

    /// Check for crash from a previous daemon run and blacklist the culprit.
    public func recoverFromCrash() {
        if let crashedTask = crashTracker.checkForCrash() {
            crashTracker.blacklist(taskName: crashedTask)
            logger.error("Previous daemon crash caused by task: \(crashedTask) — blacklisted")
        }
    }

    public var isEmpty: Bool { scheduledTasks.isEmpty }
    public var taskCount: Int { scheduledTasks.count }
    public var taskNames: Set<String> { Set(scheduledTasks.keys) }

    public func scheduledTask(named name: String) -> ScheduledTask? {
        scheduledTasks[name]
    }

    public func triggerTask(name: String) {
        guard scheduledTasks[name] != nil else { return }
        scheduledTasks[name]?.nextRun = Date.now
        scheduledTasks[name]?.pendingRunReason = .triggered
    }

    private func backoffInterval(for scheduled: ScheduledTask) -> TimeInterval {
        Self.backoffInterval(
            baseInterval: scheduled.task.schedule.intervalSeconds,
            consecutiveFailures: scheduled.consecutiveFailures,
            backoffEnabled: scheduled.task.schedule.backoffOnFailure
        )
    }

    public static func backoffInterval(
        baseInterval: TimeInterval,
        consecutiveFailures: Int,
        backoffEnabled: Bool
    ) -> TimeInterval {
        guard backoffEnabled, consecutiveFailures > 0 else {
            return baseInterval
        }
        let maxBackoff = baseInterval * Double(1 << min(consecutiveFailures, 6))
        let capped = min(maxBackoff, 3600)
        return Double.random(in: baseInterval...capped)
    }
}
