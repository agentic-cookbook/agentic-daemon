import Foundation
import os

// Wraps a non-Sendable ObjC callback block for safe capture in Swift 6 Tasks.
// Safe here because NSXPCConnection callbacks are designed to be called from any thread.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

public final class XPCService: NSObject, AgenticDaemonXPCProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.agentic-cookbook.daemon", category: "XPCService")
    private let scheduler: Scheduler
    private let jobRunStore: JobRunStore
    private let crashTracker: CrashTracker
    private let startTime: Date
    private var listener: NSXPCListener?
    private var listenerDelegate: XPCListenerDelegate?

    public init(
        scheduler: Scheduler,
        jobRunStore: JobRunStore,
        crashTracker: CrashTracker,
        startTime: Date
    ) {
        self.scheduler = scheduler
        self.jobRunStore = jobRunStore
        self.crashTracker = crashTracker
        self.startTime = startTime
    }

    public func start() {
        let delegate = XPCListenerDelegate(service: self)
        let l = NSXPCListener(machServiceName: "com.agentic-cookbook.daemon")
        l.delegate = delegate
        l.resume()
        listenerDelegate = delegate
        listener = l
        logger.info("XPC service registered")
    }

    public func stop() {
        listener?.invalidate()
        listener = nil
        listenerDelegate = nil
    }

    // MARK: - AgenticDaemonXPCProtocol

    public func healthCheck(reply: @escaping (Data) -> Void) {
        let scheduler = self.scheduler
        let startTime = self.startTime
        let replyBox = SendableBox(value: reply)
        Task {
            let uptime = Date().timeIntervalSince(startTime)
            let count = await scheduler.taskCount
            let payload: [String: Any] = [
                "status": "ok",
                "uptimeSeconds": uptime,
                "jobCount": count,
                "version": "1.0.0"
            ]
            replyBox.value((try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }
    }

    public func listJobs(reply: @escaping ([Data]) -> Void) {
        let scheduler = self.scheduler
        let crashTracker = self.crashTracker
        let replyBox = SendableBox(value: reply)
        Task {
            let names = await scheduler.taskNames
            var items: [Data] = []
            for name in names.sorted() {
                guard let job = await scheduler.scheduledTask(named: name) else { continue }
                let payload: [String: Any] = [
                    "name": name,
                    "consecutiveFailures": job.consecutiveFailures,
                    "isRunning": job.isRunning,
                    "isBlacklisted": crashTracker.isBlacklisted(taskName: name)
                ]
                if let d = try? JSONSerialization.data(withJSONObject: payload) {
                    items.append(d)
                }
            }
            replyBox.value(items)
        }
    }

    public func jobRuns(jobName: String, limit: Int, reply: @escaping ([Data]) -> Void) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let runs = jobRunStore.runs(for: jobName, limit: limit)
        reply(runs.compactMap { try? encoder.encode($0) })
    }

    public func recentRuns(limit: Int, reply: @escaping ([Data]) -> Void) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let runs = jobRunStore.recentRuns(limit: limit)
        reply(runs.compactMap { try? encoder.encode($0) })
    }
}

// MARK: - Listener delegate

private final class XPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: XPCService

    init(service: XPCService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AgenticDaemonXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
