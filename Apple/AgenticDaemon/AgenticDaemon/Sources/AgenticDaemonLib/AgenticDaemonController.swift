import Foundation
import os
import DaemonKit

public final class AgenticDaemonController: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "AgenticDaemonController"
    )

    private let engine: DaemonEngine
    private let strategy: TimingStrategy
    private let taskSource: ScriptTaskSource
    private let discovery: JobDiscovery
    private let jobsDirectory: URL

    public init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let supportDirectory = appSupport.appending(path: "com.agentic-cookbook.daemon")
        let jobsDir = supportDirectory.appending(path: "jobs")
        let libDir = supportDirectory.appending(path: "lib")
        let identifier = "com.agentic-cookbook.daemon"

        let analytics: any AnalyticsProvider = LogAnalyticsProvider(subsystem: identifier)
        let discovery = JobDiscovery(jobsDirectory: jobsDir)
        let compiler = SwiftCompiler(buildDir: libDir)
        let loader = JobLoader()

        let source = ScriptTaskSource(
            discovery: discovery,
            compiler: compiler,
            loader: loader,
            analytics: analytics,
            jobsDirectory: jobsDir
        )

        let configuration = DaemonConfiguration(
            identifier: identifier,
            supportDirectory: supportDirectory,
            machServiceName: "com.agentic-cookbook.daemon.xpc",
            crashReportProcessName: "agentic-daemon"
        )

        let strategy = TimingStrategy(name: "agentic-jobs", taskSource: source)

        self.jobsDirectory = jobsDir
        self.discovery = discovery
        self.taskSource = source
        self.strategy = strategy
        self.engine = DaemonEngine(
            configuration: configuration,
            strategy: strategy,
            analytics: analytics
        )
    }

    public func run() async {
        logger.info("Starting agentic-daemon")

        createClientDirectories()

        let handler = makeXPCHandler()
        await engine.run(
            xpcExportedObject: handler,
            xpcInterface: NSXPCInterface(with: AgenticDaemonXPC.self)
        )
    }

    public func shutdown() {
        engine.shutdown()
    }

    // MARK: - XPC

    private func makeXPCHandler() -> XPCHandler {
        let engine = self.engine
        let strategy = self.strategy
        let jobsDir = self.jobsDirectory

        return XPCHandler(dependencies: .init(
            getStatus: {
                let names = await strategy.taskNames
                var jobs: [DaemonStatus.JobStatus] = []
                for name in names.sorted() {
                    guard let st = await strategy.scheduledTask(named: name) else { continue }
                    let config: JobConfig
                    if let scriptTask = st.task as? ScriptDaemonTask {
                        config = scriptTask.descriptor.config
                    } else {
                        config = .default
                    }
                    jobs.append(DaemonStatus.JobStatus(
                        name: name,
                        nextRun: st.nextRun,
                        consecutiveFailures: st.consecutiveFailures,
                        isRunning: st.isRunning,
                        config: config,
                        isBlacklisted: engine.crashTracker.isBlacklisted(taskName: name)
                    ))
                }
                return DaemonStatus(
                    uptimeSeconds: Date.now.timeIntervalSince(engine.startDate),
                    jobCount: jobs.count,
                    lastTick: Date.now,
                    jobs: jobs
                )
            },
            getCrashReports: {
                engine.crashReportStore.loadAll()
                    .sorted { $0.timestamp > $1.timestamp }
            },
            enableJob: { name in
                let configURL = jobsDir
                    .appending(path: name)
                    .appending(path: "config.json")
                return await Self.updateJobEnabled(
                    true, at: configURL,
                    strategy: strategy
                )
            },
            disableJob: { name in
                let configURL = jobsDir
                    .appending(path: name)
                    .appending(path: "config.json")
                return await Self.updateJobEnabled(
                    false, at: configURL,
                    strategy: strategy
                )
            },
            triggerJob: { name in
                let exists = await strategy.taskNames.contains(name)
                guard exists else { return false }
                await strategy.triggerTask(name: name)
                return true
            },
            clearBlacklist: { name in
                engine.crashTracker.clearBlacklist(taskName: name)
                return true
            },
            onShutdown: { [weak self] in self?.shutdown() }
        ))
    }

    private static func updateJobEnabled(
        _ enabled: Bool,
        at configURL: URL,
        strategy: TimingStrategy
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

        await strategy.syncTasks()
        return true
    }

    // MARK: - Private

    private func createClientDirectories() {
        let fm = FileManager.default
        let dirs = [
            jobsDirectory,
            jobsDirectory.deletingLastPathComponent().appending(path: "lib")
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
