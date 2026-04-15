import DaemonKit

// MARK: - Client-specific analytics event kinds
extension AnalyticsEvent.Kind {
    static let jobDiscovered = AnalyticsEvent.Kind("job_discovered")
    static let jobCompiled   = AnalyticsEvent.Kind("job_compiled")
}

extension AnalyticsEvent {
    static func jobDiscovered(name: String) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobDiscovered, properties: ["name": name])
    }

    static func jobCompiled(name: String, durationSeconds: Double) -> AnalyticsEvent {
        AnalyticsEvent(kind: .jobCompiled, properties: ["name": name, "durationSeconds": durationSeconds])
    }
}
