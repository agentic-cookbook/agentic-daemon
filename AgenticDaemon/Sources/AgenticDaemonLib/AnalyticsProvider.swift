import Foundation
import os

public struct AnalyticsEvent: Sendable {
    public enum Kind: String, Sendable, Equatable {
        case jobDiscovered = "job_discovered"
        case jobCompiled = "job_compiled"
        case jobStarted = "job_started"
        case jobCompleted = "job_completed"
        case jobFailed = "job_failed"
        case jobTimedOut = "job_timed_out"
        case jobCrashed = "job_crashed"
    }

    public let kind: Kind
    public let properties: [String: any Sendable]
    public let timestamp: Date

    private init(kind: Kind, properties: [String: any Sendable]) {
        self.kind = kind
        self.properties = properties
        self.timestamp = Date.now
    }

    public static func jobDiscovered(name: String) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobDiscovered, properties: ["name": name])
    }

    public static func jobCompiled(name: String, durationSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobCompiled, properties: ["name": name, "durationSeconds": durationSeconds])
    }

    public static func jobStarted(name: String) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobStarted, properties: ["name": name])
    }

    public static func jobCompleted(name: String, exitCode: Int32, durationSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobCompleted, properties: ["name": name, "exitCode": exitCode, "durationSeconds": durationSeconds])
    }

    public static func jobFailed(name: String, exitCode: Int32, durationSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobFailed, properties: ["name": name, "exitCode": exitCode, "durationSeconds": durationSeconds])
    }

    public static func jobTimedOut(name: String, timeoutSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobTimedOut, properties: ["name": name, "timeoutSeconds": timeoutSeconds])
    }

    public static func jobCrashed(name: String, signal: String?, exceptionType: String?) -> AnalyticsEvent {
        var props: [String: any Sendable] = ["name": name]
        if let signal { props["signal"] = signal }
        if let exceptionType { props["exceptionType"] = exceptionType }
        return AnalyticsEvent(kind: .jobCrashed, properties: props)
    }
}

public protocol AnalyticsProvider: Sendable {
    func track(_ event: AnalyticsEvent)
}

public struct LogAnalyticsProvider: AnalyticsProvider {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "Analytics"
    )

    public init() {}

    public func track(_ event: AnalyticsEvent) {
        let name = event.properties["name"] as? String ?? "unknown"
        switch event.kind {
        case .jobDiscovered:
            logger.info("[\(event.kind.rawValue)] \(name)")
        case .jobCompiled:
            let duration = event.properties["durationSeconds"] as? Double ?? 0
            logger.info("[\(event.kind.rawValue)] \(name) in \(duration, format: .fixed(precision: 2))s")
        case .jobStarted:
            logger.info("[\(event.kind.rawValue)] \(name)")
        case .jobCompleted:
            let duration = event.properties["durationSeconds"] as? Double ?? 0
            let exitCode = event.properties["exitCode"] as? Int32 ?? -1
            logger.info("[\(event.kind.rawValue)] \(name) exit=\(exitCode) in \(duration, format: .fixed(precision: 2))s")
        case .jobFailed:
            let duration = event.properties["durationSeconds"] as? Double ?? 0
            let exitCode = event.properties["exitCode"] as? Int32 ?? -1
            logger.error("[\(event.kind.rawValue)] \(name) exit=\(exitCode) in \(duration, format: .fixed(precision: 2))s")
        case .jobTimedOut:
            let timeout = event.properties["timeoutSeconds"] as? Double ?? 0
            logger.warning("[\(event.kind.rawValue)] \(name) after \(timeout, format: .fixed(precision: 0))s")
        case .jobCrashed:
            let signal = event.properties["signal"] as? String ?? "unknown"
            let excType = event.properties["exceptionType"] as? String ?? "unknown"
            logger.error("[\(event.kind.rawValue)] \(name) signal=\(signal) exception=\(excType)")
        }
    }
}
