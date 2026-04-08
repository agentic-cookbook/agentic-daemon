import Foundation
import os

public actor Scheduler {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "Scheduler"
    )
    private let compiler = SwiftCompiler()
    private let runner = JobRunner()
    private var scheduledJobs: [String: ScheduledJob] = [:]
    private nonisolated(unsafe) var runningProcesses: [String: Process] = [:]
    private let processLock = NSLock()

    public struct ScheduledJob: Sendable {
        public let descriptor: JobDescriptor
        public var nextRun: Date
        public var consecutiveFailures: Int = 0
        public var isRunning: Bool = false
    }

    public init() {}

    public func syncJobs(discovered: [JobDescriptor]) {
        let discoveredNames = Set(discovered.map(\.name))
        let currentNames = Set(scheduledJobs.keys)

        for job in discovered where !currentNames.contains(job.name) {
            guard job.config.enabled else {
                logger.info("Skipping disabled job: \(job.name)")
                continue
            }
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
            Task.detached(priority: .utility) { [self] in
                let process = runner.launch(job: descriptor)

                if let process {
                    self.processLock.withLock {
                        self.runningProcesses[descriptor.name] = process
                    }

                    self.runner.waitForCompletion(process: process, job: descriptor)

                    _ = self.processLock.withLock {
                        self.runningProcesses.removeValue(forKey: descriptor.name)
                    }
                }

                await self.markJobCompleted(name: descriptor.name)
            }
        }
    }

    private func markJobCompleted(name: String) {
        if var entry = scheduledJobs[name] {
            let interval = backoffInterval(for: entry)
            entry.nextRun = Date.now.addingTimeInterval(interval)
            entry.isRunning = false
            scheduledJobs[name] = entry
        }
    }

    public nonisolated func terminateAllRunning(gracePeriod: TimeInterval) {
        processLock.lock()
        let processes = Array(runningProcesses.values)
        processLock.unlock()

        guard !processes.isEmpty else { return }

        logger.info("Terminating \(processes.count) running process(es)")

        for process in processes where process.isRunning {
            process.terminate()
        }

        let deadline = Date.now.addingTimeInterval(gracePeriod)
        for process in processes {
            while process.isRunning && Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                logger.warning("Force-killing process that didn't exit within grace period")
                kill(process.processIdentifier, SIGKILL)
            }
        }

        for process in processes {
            process.waitUntilExit()
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

    private func compileIfNeeded(job: JobDescriptor) {
        guard compiler.needsCompile(job: job) else { return }
        do {
            try compiler.compile(job: job)
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
