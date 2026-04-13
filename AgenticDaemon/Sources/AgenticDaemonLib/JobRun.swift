import Foundation

public struct JobRun: Codable, Sendable {
    public let id: UUID
    public let jobName: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Double
    public let success: Bool
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        jobName: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.jobName = jobName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.success = success
        self.errorMessage = errorMessage
    }
}
