import Foundation

public struct JobConfig: Codable, Sendable {
    public let intervalSeconds: TimeInterval
    public let enabled: Bool
    public let timeout: TimeInterval
    public let runAtWake: Bool
    public let backoffOnFailure: Bool

    public init(
        intervalSeconds: TimeInterval = 60,
        enabled: Bool = true,
        timeout: TimeInterval = 30,
        runAtWake: Bool = true,
        backoffOnFailure: Bool = true
    ) {
        self.intervalSeconds = intervalSeconds
        self.enabled = enabled
        self.timeout = timeout
        self.runAtWake = runAtWake
        self.backoffOnFailure = backoffOnFailure
    }

    public static let `default` = JobConfig()
}
