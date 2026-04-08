import Foundation
import os

public final class Scheduler: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "Scheduler"
    )
    private let compiler = SwiftCompiler()
    private let runner = JobRunner()
    private let lock = NSLock()
    private var scheduledJobs: [String: ScheduledJob] = [:]
    private var runningProcesses: [String: Process] = [:]

    public struct ScheduledJob: Sendable {
        public let descriptor: JobDescriptor
        public var nextRun: Date
        public var consecutiveFailures: Int = 0
        public var isRunning: Bool = false
    }

    public init() {}

    public func syncJobs(discovered: [JobDescriptor]) {
        lock.lock()
        defer { lock.unlock() }

        let discoveredNames = Set(discovered.map(\.name))
        let currentNames = Set(scheduledJobs.keys)

        // Add new jobs
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

        // Remove deleted jobs
        for name in currentNames.subtracting(discoveredNames) {
            scheduledJobs.removeValue(forKey: name)
            logger.info("Removed job: \(name)")
        }

        // Recompile changed sources
        for job in discovered where currentNames.contains(job.name) {
            if compiler.needsCompile(job: job) {
                logger.info("Source changed for \(job.name), recompiling")
                compileIfNeeded(job: job)
            }
        }
    }

    public func tick() {
        lock.lock()
        let now = Date.now
        var jobsToRun: [ScheduledJob] = []

        for (_, job) in scheduledJobs where job.nextRun <= now && !job.isRunning {
            jobsToRun.append(job)
        }
        for job in jobsToRun {
            scheduledJobs[job.descriptor.name]?.isRunning = true
        }
        lock.unlock()

        for job in jobsToRun {
            let descriptor = job.descriptor
            DispatchQueue.global(qos: .utility).async { [self] in
                let process = runner.launch(job: descriptor)

                if let process {
                    lock.lock()
                    runningProcesses[descriptor.name] = process
                    lock.unlock()

                    runner.waitForCompletion(process: process, job: descriptor)

                    lock.lock()
                    runningProcesses.removeValue(forKey: descriptor.name)
                    lock.unlock()
                }

                lock.lock()
                if var entry = scheduledJobs[descriptor.name] {
                    let interval = backoffInterval(for: entry)
                    entry.nextRun = Date.now.addingTimeInterval(interval)
                    entry.isRunning = false
                    scheduledJobs[descriptor.name] = entry
                }
                lock.unlock()
            }
        }
    }

    public func terminateAllRunning(gracePeriod: TimeInterval) {
        lock.lock()
        let processes = Array(runningProcesses.values)
        lock.unlock()

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
        lock.lock()
        defer { lock.unlock() }
        return scheduledJobs.isEmpty
    }

    public var jobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledJobs.count
    }

    public var jobNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(scheduledJobs.keys)
    }

    public func job(named name: String) -> ScheduledJob? {
        lock.lock()
        defer { lock.unlock() }
        return scheduledJobs[name]
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
        guard job.descriptor.config.backoffOnFailure,
              job.consecutiveFailures > 0 else {
            return job.descriptor.config.intervalSeconds
        }
        let backoff = job.descriptor.config.intervalSeconds * Double(1 << min(job.consecutiveFailures, 6))
        return min(backoff, 3600)
    }
}
