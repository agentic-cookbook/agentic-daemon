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
    private let analytics: any AnalyticsProvider
    private var watcher: DirectoryWatcher?
    private var running = true
    private let startDate = Date.now

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
        scheduler = Scheduler(buildDir: libDir, crashTracker: crashTracker, analytics: analytics)
    }

    public func run() async {
        logger.info("Starting agentic-daemon")

        createDirectories()

        do {
            try crashReportCollector.installCrashHandler()
        } catch {
            logger.error("Failed to install crash handler: \(error)")
        }

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

        crashReportStore.cleanup(retentionDays: 30)
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

        // Start XPC server so the menu bar companion can connect
        let xpcServer = XPCServer(handler: makeXPCHandler())
        xpcServer.start()

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

    // MARK: - XPC

    private func makeXPCHandler() -> XPCHandler {
        let captured = (
            scheduler: scheduler,
            discovery: discovery,
            crashTracker: crashTracker,
            crashReportStore: crashReportStore,
            jobsDirectory: jobsDirectory,
            startDate: startDate
        )

        return XPCHandler(dependencies: .init(
            getStatus: {
                let names = await captured.scheduler.jobNames
                var jobs: [DaemonStatus.JobStatus] = []
                for name in names.sorted() {
                    guard let sj = await captured.scheduler.job(named: name) else { continue }
                    jobs.append(DaemonStatus.JobStatus(
                        name: sj.descriptor.name,
                        nextRun: sj.nextRun,
                        consecutiveFailures: sj.consecutiveFailures,
                        isRunning: sj.isRunning,
                        config: sj.descriptor.config,
                        isBlacklisted: captured.crashTracker.isBlacklisted(jobName: name)
                    ))
                }
                return DaemonStatus(
                    uptimeSeconds: Date.now.timeIntervalSince(captured.startDate),
                    jobCount: jobs.count,
                    lastTick: Date.now,
                    jobs: jobs
                )
            },
            getCrashReports: {
                captured.crashReportStore.loadAll()
                    .sorted { $0.timestamp > $1.timestamp }
            },
            enableJob: { name in
                let configURL = captured.jobsDirectory
                    .appending(path: name)
                    .appending(path: "config.json")
                return await Self.updateJobEnabled(true, at: configURL, discovery: captured.discovery, scheduler: captured.scheduler)
            },
            disableJob: { name in
                let configURL = captured.jobsDirectory
                    .appending(path: name)
                    .appending(path: "config.json")
                return await Self.updateJobEnabled(false, at: configURL, discovery: captured.discovery, scheduler: captured.scheduler)
            },
            triggerJob: { name in
                let exists = await captured.scheduler.jobNames.contains(name)
                guard exists else { return false }
                await captured.scheduler.triggerJob(name: name)
                return true
            },
            clearBlacklist: { name in
                captured.crashTracker.clearBlacklist(jobName: name)
                return true
            },
            onShutdown: { [weak self] in self?.shutdown() }
        ))
    }

    /// Writes an updated `enabled` flag to `config.json`, then re-syncs the scheduler.
    /// Uses a static method to avoid capturing `self` in a Sendable closure.
    private static func updateJobEnabled(
        _ enabled: Bool,
        at configURL: URL,
        discovery: JobDiscovery,
        scheduler: Scheduler
    ) async -> Bool {
        let existing: JobConfig
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(JobConfig.self, from: data) {
            existing = decoded
        } else {
            existing = .default
        }

        let updated = JobConfig(
            intervalSeconds: existing.intervalSeconds,
            enabled: enabled,
            timeout: existing.timeout,
            runAtWake: existing.runAtWake,
            backoffOnFailure: existing.backoffOnFailure
        )

        guard let data = try? JSONEncoder().encode(updated) else { return false }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            return false
        }

        let jobs = discovery.discover()
        await scheduler.syncJobs(discovered: jobs)
        return true
    }

    // MARK: - Private

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
