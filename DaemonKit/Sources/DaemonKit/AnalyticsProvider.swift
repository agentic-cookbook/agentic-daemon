import Foundation
import os

/// An extensible event kind. Framework defines standard task lifecycle kinds.
/// Clients extend with their own by declaring static constants:
///
///     extension AnalyticsEvent.Kind {
///         static let jobCompiled = AnalyticsEvent.Kind("job_compiled")
///     }
public struct AnalyticsEvent: Sendable {
    public struct Kind: RawRepresentable, Sendable, Equatable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }

    public let kind: Kind
    public let properties: [String: any Sendable]
    public let timestamp: Date

    public init(kind: Kind, properties: [String: any Sendable] = [:]) {
        self.kind = kind
        self.properties = properties
        self.timestamp = Date.now
    }
}

// MARK: - Standard framework event kinds
public extension AnalyticsEvent.Kind {
    static let taskStarted   = AnalyticsEvent.Kind("task_started")
    static let taskCompleted = AnalyticsEvent.Kind("task_completed")
    static let taskFailed    = AnalyticsEvent.Kind("task_failed")
    static let taskTimedOut  = AnalyticsEvent.Kind("task_timed_out")
    static let taskCrashed   = AnalyticsEvent.Kind("task_crashed")
}

// MARK: - Factory helpers
public extension AnalyticsEvent {
    static func taskStarted(name: String) -> AnalyticsEvent {
        AnalyticsEvent(kind: .taskStarted, properties: ["name": name])
    }

    static func taskCompleted(name: String, durationSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .taskCompleted, properties: ["name": name, "durationSeconds": durationSeconds])
    }

    static func taskFailed(name: String, durationSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .taskFailed, properties: ["name": name, "durationSeconds": durationSeconds])
    }

    static func taskTimedOut(name: String, timeoutSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .taskTimedOut, properties: ["name": name, "timeoutSeconds": timeoutSeconds])
    }

    static func taskCrashed(name: String, signal: String?, exceptionType: String?) -> AnalyticsEvent {
        var props: [String: any Sendable] = ["name": name]
        if let signal { props["signal"] = signal }
        if let exceptionType { props["exceptionType"] = exceptionType }
        return AnalyticsEvent(kind: .taskCrashed, properties: props)
    }
}

public protocol AnalyticsProvider: Sendable {
    func track(_ event: AnalyticsEvent)
}

/// Default implementation: logs every event via os.log.
public struct LogAnalyticsProvider: AnalyticsProvider {
    private let logger: Logger

    public init(subsystem: String) {
        self.logger = Logger(subsystem: subsystem, category: "Analytics")
    }

    public func track(_ event: AnalyticsEvent) {
        let name = event.properties["name"] as? String ?? "unknown"
        let kind = event.kind.rawValue
        switch event.kind {
        case .taskStarted:
            logger.info("[\(kind)] \(name)")
        case .taskCompleted:
            let d = event.properties["durationSeconds"] as? Double ?? 0
            logger.info("[\(kind)] \(name) in \(d, format: .fixed(precision: 2))s")
        case .taskFailed:
            let d = event.properties["durationSeconds"] as? Double ?? 0
            logger.error("[\(kind)] \(name) in \(d, format: .fixed(precision: 2))s")
        case .taskTimedOut:
            let t = event.properties["timeoutSeconds"] as? Double ?? 0
            logger.warning("[\(kind)] \(name) after \(t, format: .fixed(precision: 0))s")
        case .taskCrashed:
            let sig = event.properties["signal"] as? String ?? "unknown"
            let exc = event.properties["exceptionType"] as? String ?? "unknown"
            logger.error("[\(kind)] \(name) signal=\(sig) exception=\(exc)")
        default:
            logger.info("[\(kind)] \(name)")
        }
    }
}
