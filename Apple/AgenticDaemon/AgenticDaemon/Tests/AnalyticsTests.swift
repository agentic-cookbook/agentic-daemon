import Testing
import Foundation
@testable import AgenticDaemonLib

/// In-memory analytics provider for testing
final class MockAnalyticsProvider: AnalyticsProvider, @unchecked Sendable {
    private var _events: [AnalyticsEvent] = []
    private let lock = NSLock()

    var events: [AnalyticsEvent] {
        lock.withLock { _events }
    }

    func track(_ event: AnalyticsEvent) {
        lock.withLock { _events.append(event) }
    }
}

@Suite("Analytics")
struct AnalyticsTests {

    @Test("track records job_discovered event")
    func tracksDiscovered() {
        let provider = MockAnalyticsProvider()
        provider.track(.jobDiscovered(name: "my-job"))

        let events = provider.events
        #expect(events.count == 1)
        #expect(events[0].kind == .jobDiscovered)
        #expect(events[0].properties["name"] as? String == "my-job")
    }

    @Test("track records job_compiled event")
    func tracksCompiled() {
        let provider = MockAnalyticsProvider()
        provider.track(.jobCompiled(name: "my-job", durationSeconds: 1.5))

        let events = provider.events
        #expect(events.count == 1)
        #expect(events[0].kind == .jobCompiled)
        #expect(events[0].properties["name"] as? String == "my-job")
        #expect(events[0].properties["durationSeconds"] as? Double == 1.5)
    }

    @Test("track records task_started event")
    func tracksStarted() {
        let provider = MockAnalyticsProvider()
        provider.track(.taskStarted(name: "my-job"))

        let events = provider.events
        #expect(events[0].kind == .taskStarted)
        #expect(events[0].properties["name"] as? String == "my-job")
    }

    @Test("track records task_completed event with duration")
    func tracksCompleted() {
        let provider = MockAnalyticsProvider()
        provider.track(.taskCompleted(name: "my-job", durationSeconds: 2.3))

        let events = provider.events
        #expect(events[0].kind == .taskCompleted)
        #expect(events[0].properties["name"] as? String == "my-job")
        #expect(events[0].properties["durationSeconds"] as? Double == 2.3)
    }

    @Test("track records task_failed event with duration")
    func tracksFailed() {
        let provider = MockAnalyticsProvider()
        provider.track(.taskFailed(name: "my-job", durationSeconds: 0.5))

        let events = provider.events
        #expect(events[0].kind == .taskFailed)
        #expect(events[0].properties["durationSeconds"] as? Double == 0.5)
    }

    @Test("track records task_timed_out event with timeout value")
    func tracksTimedOut() {
        let provider = MockAnalyticsProvider()
        provider.track(.taskTimedOut(name: "my-job", timeoutSeconds: 30))

        let events = provider.events
        #expect(events[0].kind == .taskTimedOut)
        #expect(events[0].properties["timeoutSeconds"] as? Double == 30)
    }

    @Test("track records task_crashed event with signal and exception type")
    func tracksCrashed() {
        let provider = MockAnalyticsProvider()
        provider.track(.taskCrashed(
            name: "bad-plugin",
            signal: "SIGABRT",
            exceptionType: "EXC_CRASH"
        ))

        let events = provider.events
        #expect(events.count == 1)
        #expect(events[0].kind == .taskCrashed)
        #expect(events[0].properties["name"] as? String == "bad-plugin")
        #expect(events[0].properties["signal"] as? String == "SIGABRT")
        #expect(events[0].properties["exceptionType"] as? String == "EXC_CRASH")
    }

    @Test("LogAnalyticsProvider does not crash")
    func logProviderDoesNotCrash() {
        let provider = LogAnalyticsProvider(subsystem: "test")
        provider.track(.jobDiscovered(name: "test"))
        provider.track(.taskCompleted(name: "test", durationSeconds: 1.0))
        provider.track(.taskCrashed(name: "test", signal: "SIGABRT", exceptionType: "EXC_CRASH"))
        // No crash = pass
    }

    @Test("Multiple events accumulate in order")
    func multipleEvents() {
        let provider = MockAnalyticsProvider()
        provider.track(.jobDiscovered(name: "a"))
        provider.track(.taskStarted(name: "a"))
        provider.track(.taskCompleted(name: "a", durationSeconds: 1.0))

        let kinds = provider.events.map(\.kind)
        #expect(kinds == [.jobDiscovered, .taskStarted, .taskCompleted])
    }
}
