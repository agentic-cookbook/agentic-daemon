import Foundation
import os

/// The composition root for a DaemonKit-based daemon.
///
/// Wires together the scheduler, crash tracker, directory watcher, and XPC
/// server. Clients implement ``TaskSource`` to define what work the daemon
/// does and call ``run(xpcExportedObject:xpcInterface:)`` to start it.
///
///     let engine = DaemonEngine(
///         configuration: config,
///         taskSource: mySource,
///         analytics: LogAnalyticsProvider(subsystem: config.identifier)
///     )
///     // Optionally build an XPC handler that captures engine.scheduler, then:
///     await engine.run(xpcExportedObject: handler, xpcInterface: interface)
public final class DaemonEngine: @unchecked Sendable {
    private let logger: Logger
    private let configuration: DaemonConfiguration
    private let taskSource: any TaskSource
    private let analytics: any AnalyticsProvider
    private let _running = OSAllocatedUnfairLock(initialState: true)

    /// The crash tracker. Exposed so clients can query blacklist state.
    public let crashTracker: CrashTracker
    private let crashReportCollector: CrashReportCollector
    /// The crash report store. Exposed so clients can query crash history.
    public let crashReportStore: CrashReportStore

    /// The scheduler. Exposed so clients can build XPC handlers that capture it
    /// before calling ``run(xpcExportedObject:xpcInterface:)``.
    public let scheduler: Scheduler

    /// When the engine was created. Useful for uptime reporting.
    public let startDate = Date.now

    private var watcher: DirectoryWatcher?
    private var xpcServer: XPCServer?

    public init(
        configuration: DaemonConfiguration,
        taskSource: any TaskSource,
        analytics: any AnalyticsProvider
    ) {
        let subsystem = configuration.identifier
        self.logger = Logger(subsystem: subsystem, category: "DaemonEngine")
        self.configuration = configuration
        self.taskSource = taskSource
        self.analytics = analytics

        crashTracker = CrashTracker(stateDir: configuration.supportDirectory, subsystem: subsystem)
        crashReportCollector = CrashReportCollector(
            supportDirectory: configuration.supportDirectory,
            processName: configuration.crashReportProcessName,
            subsystem: subsystem
        )
        crashReportStore = CrashReportStore(
            crashesDirectory: configuration.crashesDirectory,
            subsystem: subsystem
        )
        scheduler = Scheduler(crashTracker: crashTracker, analytics: analytics, subsystem: subsystem)
    }

    /// Start the daemon. Blocks until ``shutdown()`` is called.
    ///
    /// - Parameters:
    ///   - xpcExportedObject: An NSObject to export over XPC. Required if
    ///     `configuration.machServiceName` is set.
    ///   - xpcInterface: The ``NSXPCInterface`` describing the protocol.
    public func run(
        xpcExportedObject: AnyObject? = nil,
        xpcInterface: NSXPCInterface? = nil
    ) async {
        logger.info("Starting daemon: \(self.configuration.identifier)")

        createDirectories()

        do {
            try crashReportCollector.installCrashHandler()
        } catch {
            logger.error("Failed to install crash handler: \(error)")
        }

        if let crashedTask = crashTracker.crashedTaskName() {
            let reports = crashReportCollector.collectPendingReports(crashedTaskName: crashedTask)
            for report in reports {
                analytics.track(.taskCrashed(
                    name: report.taskName,
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
                logger.info("Crash detected for \(crashedTask) but no crash reports found")
            }
        }

        crashReportStore.cleanup(retentionDays: configuration.crashRetentionDays)
        await scheduler.recoverFromCrash()
        await scheduler.syncTasks(from: taskSource)

        if let watchDir = taskSource.watchDirectory {
            let source = taskSource
            watcher = DirectoryWatcher(directory: watchDir, subsystem: configuration.identifier) { [weak self] in
                guard let self else { return }
                Task { await self.scheduler.syncTasks(from: source) }
            }
            watcher?.start()
        }

        if let machServiceName = configuration.machServiceName,
           let exportedObject = xpcExportedObject,
           let interface = xpcInterface {
            let server = XPCServer(
                machServiceName: machServiceName,
                interface: interface,
                exportedObject: exportedObject,
                subsystem: configuration.identifier
            )
            server.start()
            self.xpcServer = server
        }

        let taskCount = await scheduler.taskCount
        logger.info("Daemon running, \(taskCount) task(s) loaded")

        while _running.withLock({ $0 }) {
            await scheduler.tick()
            try? await Task.sleep(for: .seconds(configuration.tickInterval))
        }

        watcher?.stop()
        logger.info("Daemon stopped")
    }

    public func shutdown() {
        logger.info("Shutdown requested")
        _running.withLock { $0 = false }
    }

    // MARK: - Private

    private func createDirectories() {
        let fm = FileManager.default
        let dirs = [
            configuration.supportDirectory,
            configuration.crashesDirectory
        ]
        for dir in dirs {
            let path = dir.path(percentEncoded: false)
            guard !fm.fileExists(atPath: path) else { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                logger.info("Created directory: \(path)")
            } catch {
                logger.error("Failed to create directory \(path): \(error)")
            }
        }
    }
}
