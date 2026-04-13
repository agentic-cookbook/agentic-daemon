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
        self.intervalSeconds = Self.clamp(intervalSeconds, min: 1, max: 86400)
        self.enabled = enabled
        self.timeout = Self.clamp(timeout, min: 1, max: 3600)
        self.runAtWake = runAtWake
        self.backoffOnFailure = backoffOnFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let interval = try container.decodeIfPresent(TimeInterval.self, forKey: .intervalSeconds) ?? 60
        let enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 30
        let runAtWake = try container.decodeIfPresent(Bool.self, forKey: .runAtWake) ?? true
        let backoffOnFailure = try container.decodeIfPresent(Bool.self, forKey: .backoffOnFailure) ?? true
        self.init(
            intervalSeconds: interval,
            enabled: enabled,
            timeout: timeout,
            runAtWake: runAtWake,
            backoffOnFailure: backoffOnFailure
        )
    }

    public static let `default` = JobConfig()

    private static func clamp(_ value: TimeInterval, min: TimeInterval, max: TimeInterval) -> TimeInterval {
        Swift.max(min, Swift.min(value, max))
    }
}
