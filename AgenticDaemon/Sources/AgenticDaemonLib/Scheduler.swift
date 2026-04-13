import Foundation
import os
import AgenticJobKit

public actor Scheduler {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "Scheduler"
    )
    private let compiler: SwiftCompiler
    private let loader = JobLoader()
    private let analytics: any AnalyticsProvider
    private let crashTracker: CrashTracker
    private var scheduledJobs: [String: ScheduledJob] = [:]

    public struct ScheduledJob: Sendable {
        public let descriptor: JobDescriptor
        public var nextRun: Date
        public var consecutiveFailures: Int = 0
        public var isRunning: Bool = false
    }

    public init(
        buildDir: URL,
        crashTracker: CrashTracker? = nil,
        analytics: any AnalyticsProvider = LogAnalyticsProvider()
    ) {
        self.compiler = SwiftCompiler(buildDir: buildDir)
        self.crashTracker = crashTracker ?? CrashTracker(stateDir: buildDir)
        self.analytics = analytics
    }

    public func syncJobs(discovered: [JobDescriptor]) {
        let discoveredNames = Set(discovered.map(\.name))
        let currentNames = Set(scheduledJobs.keys)

        for job in discovered where !currentNames.contains(job.name) {
            guard job.config.enabled else {
                logger.info("Skipping disabled job: \(job.name)")
                continue
            }
            if crashTracker.isBlacklisted(jobName: job.name) {
                if compiler.needsCompile(job: job) {
                    logger.info("Source changed for blacklisted \(job.name), clearing blacklist")
                    crashTracker.clearBlacklist(jobName: job.name)
                } else {
                    logger.warning("Skipping blacklisted job: \(job.name)")
                    continue
                }
            }
            analytics.track(.jobDiscovered(name: job.name))
            compileIfNeeded(job: job)
            scheduledJobs[job.name] = ScheduledJob(
                descriptor: job,
                nextRun: Date.now
            )
            logger.info("Added job: \(job.name) (interval: \(job.config.intervalSeconds)s)")
        }

        for name in currentNames.subtracting(discoveredNames) {
            scheduledJobs.removeValue(forKey: name)
            logger.info("Removed job: \(name)")
        }

        for job in discovered where currentNames.contains(job.name) {
            if compiler.needsCompile(job: job) {
                logger.info("Source changed for \(job.name), recompiling")
                compileIfNeeded(job: job)
                if crashTracker.isBlacklisted(jobName: job.name) {
                    crashTracker.clearBlacklist(jobName: job.name)
                }
            }
        }
    }

    public func tick() {
        let now = Date.now
        var jobsToRun: [ScheduledJob] = []

        for (_, job) in scheduledJobs where job.nextRun <= now && !job.isRunning {
            jobsToRun.append(job)
        }
        for job in jobsToRun {
            scheduledJobs[job.descriptor.name]?.isRunning = true
        }

        for job in jobsToRun {
            let descriptor = job.descriptor
            let failures = job.consecutiveFailures
            Task.detached(priority: .utility) { [self] in
                await self.runJob(descriptor: descriptor, consecutiveFailures: failures)
            }
        }
    }

    private func runJob(descriptor: JobDescriptor, consecutiveFailures: Int) async {
        let name = descriptor.name
        analytics.track(.jobStarted(name: name))
        crashTracker.markRunning(jobName: name)
        let startTime = Date.now

        let request = JobRequest(
            jobName: name,
            jobDirectory: descriptor.directory,
            jobsDirectory: descriptor.directory.deletingLastPathComponent(),
            runReason: .scheduled,
            consecutiveFailures: consecutiveFailures
        )

        do {
            let response = try loader.load(descriptor: descriptor, request: request)
            let duration = Date.now.timeIntervalSince(startTime)

            crashTracker.clearRunning()
            analytics.track(.jobCompleted(name: name, exitCode: 0, durationSeconds: duration))

            await handleResponse(response, for: name)
            await markJobCompleted(name: name, failed: false)

        } catch {
            let duration = Date.now.timeIntervalSince(startTime)
            crashTracker.clearRunning()
            analytics.track(.jobFailed(name: name, exitCode: 1, durationSeconds: duration))
            logger.error("Job \(name) failed: \(error)")

            await markJobCompleted(name: name, failed: true)
        }
    }

    private func handleResponse(_ response: JobResponse, for name: String) {
        if let enabled = response.enabled, !enabled {
            scheduledJobs.removeValue(forKey: name)
            logger.info("Job \(name) disabled itself")
            return
        }

        if let triggers = response.trigger {
            for triggerName in triggers {
                if scheduledJobs[triggerName] != nil {
                    scheduledJobs[triggerName]?.nextRun = Date.now
                    logger.info("Job \(name) triggered \(triggerName)")
                } else {
                    logger.warning("Job \(name) tried to trigger unknown job: \(triggerName)")
                }
            }
        }
    }

    private func markJobCompleted(name: String, failed: Bool) {
        guard var entry = scheduledJobs[name] else { return }

        if failed {
            entry.consecutiveFailures += 1
        } else {
            entry.consecutiveFailures = 0
        }

        // Check if job's response set a custom interval
        let interval = backoffInterval(for: entry)
        entry.nextRun = Date.now.addingTimeInterval(interval)
        entry.isRunning = false
        scheduledJobs[name] = entry
    }

    /// Check for crash from a previous daemon run and blacklist the culprit.
    public func recoverFromCrash() {
        if let crashedJob = crashTracker.checkForCrash() {
            crashTracker.blacklist(jobName: crashedJob)
            logger.error("Previous daemon crash caused by job: \(crashedJob) — blacklisted")
        }
    }

    public var isEmpty: Bool {
        scheduledJobs.isEmpty
    }

    public var jobCount: Int {
        scheduledJobs.count
    }

    public var jobNames: Set<String> {
        Set(scheduledJobs.keys)
    }

    public func job(named name: String) -> ScheduledJob? {
        scheduledJobs[name]
    }

    public func triggerJob(name: String) {
        guard scheduledJobs[name] != nil else { return }
        scheduledJobs[name]?.nextRun = Date.now
    }

    private func compileIfNeeded(job: JobDescriptor) {
        guard compiler.needsCompile(job: job) else { return }
        let start = Date.now
        do {
            try compiler.compile(job: job)
            let duration = Date.now.timeIntervalSince(start)
            analytics.track(.jobCompiled(name: job.name, durationSeconds: duration))
        } catch {
            logger.error("Compile failed for \(job.name): \(error)")
        }
    }

    private func backoffInterval(for job: ScheduledJob) -> TimeInterval {
        Self.backoffInterval(
            baseInterval: job.descriptor.config.intervalSeconds,
            consecutiveFailures: job.consecutiveFailures,
            backoffEnabled: job.descriptor.config.backoffOnFailure
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
        let jittered = Double.random(in: baseInterval...capped)
        return jittered
    }
}
