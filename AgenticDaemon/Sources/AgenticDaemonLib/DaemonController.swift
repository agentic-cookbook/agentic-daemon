import Foundation
import os

public final class DaemonController: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "DaemonController"
    )

    private let supportDirectory: URL
    private let jobsDirectory: URL
    public let scheduler: Scheduler
    private let discovery: JobDiscovery
    private var watcher: DirectoryWatcher?
    private var running = true

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        supportDirectory = appSupport.appending(path: "com.agentic-cookbook.daemon")
        jobsDirectory = supportDirectory.appending(path: "jobs")
        discovery = JobDiscovery(jobsDirectory: jobsDirectory)
        let libDir = supportDirectory.appending(path: "lib")
        let crashTracker = CrashTracker(stateDir: supportDirectory)
        scheduler = Scheduler(buildDir: libDir, crashTracker: crashTracker)
    }

    public func run() async {
        logger.info("Starting agentic-daemon")

        createDirectories()

        await scheduler.recoverFromCrash()

        let jobs = discovery.discover()
        await scheduler.syncJobs(discovered: jobs)

        watcher = DirectoryWatcher(directory: jobsDirectory) { [self] in
            Task {
                let updated = self.discovery.discover()
                await self.scheduler.syncJobs(discovered: updated)
            }
        }
        watcher?.start()

        logger.info("Daemon running, \(jobs.count) job(s) loaded")

        while running {
            await scheduler.tick()
            try? await Task.sleep(for: .seconds(1))
        }

        watcher?.stop()
        logger.info("Daemon stopped")
    }

    public func shutdown() {
        logger.info("Shutdown requested")
        running = false
    }

    private func createDirectories() {
        let fm = FileManager.default
        for dir in [jobsDirectory, supportDirectory.appending(path: "lib")] {
            let path = dir.path(percentEncoded: false)
            if !fm.fileExists(atPath: path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    logger.info("Created directory: \(path)")
                } catch {
                    logger.error("Failed to create directory: \(error)")
                }
            }
        }
    }
}
