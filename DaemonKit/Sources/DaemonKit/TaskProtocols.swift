import Foundation

/// A unit of work the daemon schedules and runs.
/// Clients implement this protocol to define what their daemon does.
public protocol DaemonTask: Sendable {
    /// Unique identifier for this task.
    var name: String { get }

    /// Scheduling configuration for this task.
    var schedule: TaskSchedule { get }

    /// Execute the task and return a result that can influence future scheduling.
    func execute(context: TaskContext) async throws -> TaskResult
}

/// Scheduling configuration for a daemon task.
public struct TaskSchedule: Sendable {
    /// How often to run, in seconds. Clamped to 1...86400.
    public let intervalSeconds: TimeInterval
    /// Whether the task is currently enabled.
    public let enabled: Bool
    /// Maximum execution time in seconds. Clamped to 1...3600.
    public let timeout: TimeInterval
    /// Whether to apply exponential backoff on consecutive failures.
    public let backoffOnFailure: Bool

    public init(
        intervalSeconds: TimeInterval = 60,
        enabled: Bool = true,
        timeout: TimeInterval = 30,
        backoffOnFailure: Bool = true
    ) {
        self.intervalSeconds = min(max(intervalSeconds, 1), 86400)
        self.enabled = enabled
        self.timeout = min(max(timeout, 1), 3600)
        self.backoffOnFailure = backoffOnFailure
    }

    public static let `default` = TaskSchedule()
}

/// Context passed to a task at execution time.
public struct TaskContext: Sendable {
    /// The task's name.
    public let taskName: String
    /// How many times this task has failed consecutively.
    public let consecutiveFailures: Int
    /// Why this execution was triggered.
    public let runReason: RunReason

    public enum RunReason: String, Sendable, Codable {
        case scheduled
        case triggered
    }

    public init(taskName: String, consecutiveFailures: Int, runReason: RunReason) {
        self.taskName = taskName
        self.consecutiveFailures = consecutiveFailures
        self.runReason = runReason
    }
}

/// The result a task returns after execution.
/// All fields are optional — nil means "use the default behaviour".
public struct TaskResult: Sendable {
    /// Override the next interval in seconds.
    public var nextRunSeconds: TimeInterval?
    /// Override the next run to an absolute time.
    public var nextRunAt: Date?
    /// Names of other tasks to trigger immediately after this one completes.
    public var trigger: [String]?
    /// Set to false to have the daemon stop scheduling this task.
    public var enabled: Bool?
    /// A message the engine will log on behalf of the task.
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

    public static let empty = TaskResult()
}

/// Provides tasks to the daemon engine.
/// Clients implement this to define how their tasks are discovered.
public protocol TaskSource: Sendable {
    /// Return the current set of tasks. Called at startup and on directory changes.
    func discoverTasks() -> [any DaemonTask]

    /// Directory to watch for changes. Return nil to disable watching.
    var watchDirectory: URL? { get }

    /// Return true if the crash blacklist should be cleared for this task.
    /// Called when a task that was blacklisted due to crashing is seen again.
    /// Typically returns true if the task's source/binary has changed.
    func shouldClearBlacklist(taskName: String) -> Bool
}
