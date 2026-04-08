import Foundation

/// Output returned by a job to control scheduling and trigger other jobs.
///
/// All fields are optional. A job that returns `JobResponse()` uses
/// the default scheduling from its `config.json`.
public struct JobResponse: Sendable {
    /// Override the next run interval (seconds from now).
    public var nextRunSeconds: TimeInterval?

    /// Override the next run to an absolute time.
    public var nextRunAt: Date?

    /// Trigger these jobs to run immediately.
    public var trigger: [String]?

    /// Set to `false` to disable this job. It won't run again
    /// until re-enabled via config.json or source change.
    public var enabled: Bool?

    /// Observability message logged by the daemon.
    public var message: String?

    public init(
        nextRunSeconds: TimeInterval? = nil,
        nextRunAt: Date? = nil,
        trigger: [String]? = nil,
        enabled: Bool? = nil,
        message: String? = nil
    ) {
        self.nextRunSeconds = nextRunSeconds
        self.nextRunAt = nextRunAt
        self.trigger = trigger
        self.enabled = enabled
        self.message = message
    }
}
