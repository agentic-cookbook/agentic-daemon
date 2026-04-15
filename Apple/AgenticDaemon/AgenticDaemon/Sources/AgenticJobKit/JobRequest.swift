import Foundation

/// Input provided by the daemon to a job when it runs.
public struct JobRequest: Sendable, Codable {
    public let jobName: String
    public let jobDirectory: URL
    public let jobsDirectory: URL
    public let runReason: RunReason
    public let consecutiveFailures: Int

    public enum RunReason: String, Sendable, Codable {
        case scheduled
        case triggered
    }

    public init(
        jobName: String,
        jobDirectory: URL,
        jobsDirectory: URL,
        runReason: RunReason,
        consecutiveFailures: Int
    ) {
        self.jobName = jobName
        self.jobDirectory = jobDirectory
        self.jobsDirectory = jobsDirectory
        self.runReason = runReason
        self.consecutiveFailures = consecutiveFailures
    }
}
