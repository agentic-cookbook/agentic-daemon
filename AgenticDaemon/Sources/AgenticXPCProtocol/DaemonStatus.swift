import Foundation

public struct DaemonStatus: Codable, Sendable {
    public let uptimeSeconds: TimeInterval
    public let jobCount: Int
    public let lastTick: Date
    public let jobs: [JobStatus]

    public struct JobStatus: Codable, Sendable {
        public let name: String
        public let nextRun: Date
        public let consecutiveFailures: Int
        public let isRunning: Bool
        public let config: JobConfig
        public let isBlacklisted: Bool

        public init(
            name: String,
            nextRun: Date,
            consecutiveFailures: Int,
            isRunning: Bool,
            config: JobConfig = .default,
            isBlacklisted: Bool = false
        ) {
            self.name = name
            self.nextRun = nextRun
            self.consecutiveFailures = consecutiveFailures
            self.isRunning = isRunning
            self.config = config
            self.isBlacklisted = isBlacklisted
        }
    }

    public init(uptimeSeconds: TimeInterval, jobCount: Int, lastTick: Date, jobs: [JobStatus]) {
        self.uptimeSeconds = uptimeSeconds
        self.jobCount = jobCount
        self.lastTick = lastTick
        self.jobs = jobs
    }
}
