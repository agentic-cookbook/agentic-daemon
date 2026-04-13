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
    private let crashReportStore: CrashReportStore
    private let jobRunStore: JobRunStore
    private let httpServer: HTTPServer
    private let xpcService: XPCService
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
        crashReportStore = CrashReportStore(crashesDirectory: supportDirectory.appending(path: "crashes"))
        self.analytics = analytics
        do {
            jobRunStore = try JobRunStore(databaseURL: supportDirectory.appending(path: "runs.db"))
        } catch {
            fatalError("Failed to open job run store: \(error)")
        }
        scheduler = Scheduler(buildDir: libDir, crashTracker: crashTracker, analytics: analytics, jobRunStore: jobRunStore)
        let router = HTTPRouter(
            scheduler: scheduler,
            jobRunStore: jobRunStore,
            crashTracker: crashTracker,
            startTime: Date()
        )
        httpServer = HTTPServer(router: router)
        xpcService = XPCService(
            scheduler: scheduler,
            jobRunStore: jobRunStore,
            crashTracker: crashTracker,
            startTime: Date()
        )
    }

    public func run() async {
        logger.info("Starting agentic-daemon")

        createDirectories()

        do {
            try httpServer.start()
        } catch {
            logger.error("Failed to start HTTP server: \(error)")
        }
        xpcService.start()

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
                do {
                    try crashReportStore.save(report)
                } catch {
                    logger.error("Failed to save crash report: \(error)")
                }
            }
            if reports.isEmpty {
                logger.info("Crash detected for \(crashedJob) but no crash reports found")
            }
        }

        // Clean up old crash reports and run history
        crashReportStore.cleanup(retentionDays: 30)
        jobRunStore.cleanup(retentionDays: 30)

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
        httpServer.stop()
        xpcService.stop()
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
