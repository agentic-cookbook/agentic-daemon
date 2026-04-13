import Foundation
import os

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, body: data, contentType: "application/json")
    }

    public static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, body: Data(#"{"error":"not found"}"#.utf8), contentType: "application/json")
    }
}

public struct HTTPRouter: Sendable {
    private let logger = Logger(subsystem: "com.agentic-cookbook.daemon", category: "HTTPRouter")
    let scheduler: Scheduler
    let jobRunStore: JobRunStore
    let crashTracker: CrashTracker
    let startTime: Date

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

    public func handle(method: String, path: String, body: Data?) async -> HTTPResponse {
        logger.debug("\(method) \(path)")
        switch (method, path) {
        case ("GET", "/health"):
            return await handleHealth()
        case ("GET", "/jobs"):
            return await handleJobs()
        case ("GET", "/runs"):
            return handleRecentRuns()
        case ("GET", let p) where p.hasPrefix("/jobs/") && p.hasSuffix("/runs"):
            let name = String(p.dropFirst("/jobs/".count).dropLast("/runs".count))
            return handleJobRuns(jobName: name)
        case ("GET", let p) where p.hasPrefix("/jobs/"):
            let name = String(p.dropFirst("/jobs/".count))
            return await handleJob(name: name)
        default:
            return .notFound()
        }
    }

    // MARK: - Handlers

    private struct HealthResponse: Encodable {
        let status: String
        let uptimeSeconds: Double
        let jobCount: Int
        let version: String
    }

    private func handleHealth() async -> HTTPResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let count = await scheduler.jobCount
        return .json(HealthResponse(status: "ok", uptimeSeconds: uptime, jobCount: count, version: "1.0.0"))
    }

    private struct JobSummary: Encodable {
        let name: String
        let nextRun: Date
        let consecutiveFailures: Int
        let isRunning: Bool
        let isBlacklisted: Bool
    }

    private func handleJobs() async -> HTTPResponse {
        let names = await scheduler.jobNames
        var summaries: [JobSummary] = []
        for name in names.sorted() {
            guard let job = await scheduler.job(named: name) else { continue }
            summaries.append(JobSummary(
                name: name,
                nextRun: job.nextRun,
                consecutiveFailures: job.consecutiveFailures,
                isRunning: job.isRunning,
                isBlacklisted: crashTracker.isBlacklisted(jobName: name)
            ))
        }
        return .json(summaries)
    }

    private func handleJob(name: String) async -> HTTPResponse {
        guard let job = await scheduler.job(named: name) else {
            return .notFound()
        }
        struct JobDetail: Encodable {
            let name: String
            let nextRun: Date
            let consecutiveFailures: Int
            let isRunning: Bool
            let isBlacklisted: Bool
            let recentRuns: [JobRun]
        }
        return .json(JobDetail(
            name: name,
            nextRun: job.nextRun,
            consecutiveFailures: job.consecutiveFailures,
            isRunning: job.isRunning,
            isBlacklisted: crashTracker.isBlacklisted(jobName: name),
            recentRuns: jobRunStore.runs(for: name, limit: 20)
        ))
    }

    private func handleJobRuns(jobName: String) -> HTTPResponse {
        .json(jobRunStore.runs(for: jobName, limit: 50))
    }

    private func handleRecentRuns() -> HTTPResponse {
        .json(jobRunStore.recentRuns(limit: 100))
    }
}
