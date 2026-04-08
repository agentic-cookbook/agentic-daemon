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
    private let crashTracker: CrashTracker
    private let crashReportCollector: CrashReportCollector
    private let analytics: any AnalyticsProvider
    private var watcher: DirectoryWatcher?
    private var running = true

    public init(analytics: any AnalyticsProvider = LogAnalyticsProvider()) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        supportDirectory = appSupport.appending(path: "com.agentic-cookbook.daemon")
        jobsDirectory = supportDirectory.appending(path: "jobs")
        discovery = JobDiscovery(jobsDirectory: jobsDirectory)
        let libDir = supportDirectory.appending(path: "lib")
        crashTracker = CrashTracker(stateDir: supportDirectory)
        crashReportCollector = CrashReportCollector(supportDirectory: supportDirectory)
        self.analytics = analytics
        scheduler = Scheduler(buildDir: libDir, crashTracker: crashTracker, analytics: analytics)
    }

    public func run() async {
        logger.info("Starting agentic-daemon")

        createDirectories()

        // Install crash handler for future crashes
        do {
            try crashReportCollector.installCrashHandler()
        } catch {
            logger.error("Failed to install crash handler: \(error)")
        }

        // Collect crash reports from previous crash (before recoverFromCrash clears state)
        if let crashedJob = crashTracker.crashedJobName() {
            let reports = crashReportCollector.collectPendingReports(crashedJobName: crashedJob)
            for report in reports {
                analytics.track(.jobCrashed(
                    name: report.jobName,
                    signal: report.signal,
                    exceptionType: report.exceptionType
                ))
            }
            if reports.isEmpty {
                logger.info("Crash detected for \(crashedJob) but no crash reports found")
            }
        }

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
        for dir in [jobsDirectory, supportDirectory.appending(path: "lib"), supportDirectory.appending(path: "crashes")] {
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
