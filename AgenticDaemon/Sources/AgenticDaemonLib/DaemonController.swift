import Foundation
import os

public final class DaemonController: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "DaemonController"
    )

    private let supportDirectory: URL
    private let jobsDirectory: URL
    private let scheduler = Scheduler()
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
    }

    public func run() {
        logger.info("Starting agentic-daemon")

        createDirectories()

        let jobs = discovery.discover()
        scheduler.syncJobs(discovered: jobs)

        watcher = DirectoryWatcher(directory: jobsDirectory) { [self] in
            logger.info("Jobs directory changed, re-scanning")
            let updated = discovery.discover()
            scheduler.syncJobs(discovered: updated)
        }
        watcher?.start()

        logger.info("Daemon running, \(jobs.count) job(s) loaded")

        while running {
            scheduler.tick()
            Thread.sleep(forTimeInterval: 1.0)
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
        let jobsPath = jobsDirectory.path(percentEncoded: false)
        if !fm.fileExists(atPath: jobsPath) {
            do {
                try fm.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
                logger.info("Created jobs directory: \(jobsPath)")
            } catch {
                logger.error("Failed to create jobs directory: \(error)")
            }
        }
    }
}
