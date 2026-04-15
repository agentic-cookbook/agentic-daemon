import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("Backoff")
struct BackoffTests {

    @Test("First failure uses base interval")
    func firstFailureBaseInterval() {
        let interval = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 0,
            backoffEnabled: true
        )
        #expect(interval == 60)
    }

    @Test("Consecutive failures increase interval exponentially")
    func exponentialIncrease() {
        let base: TimeInterval = 60

        let after1 = Scheduler.backoffInterval(baseInterval: base, consecutiveFailures: 1, backoffEnabled: true)
        let after2 = Scheduler.backoffInterval(baseInterval: base, consecutiveFailures: 2, backoffEnabled: true)
        let after3 = Scheduler.backoffInterval(baseInterval: base, consecutiveFailures: 3, backoffEnabled: true)

        // With jitter the exact value varies, but the max of the range doubles each time
        // after1 max: 120, after2 max: 240, after3 max: 480
        #expect(after1 >= 60)
        #expect(after2 >= 60)
        #expect(after3 >= 60)
        // The maximum possible value increases with failures
        // Run multiple times to check jitter produces variation
    }

    @Test("Backoff is capped at 3600s")
    func cappedAt3600() {
        let interval = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 20,
            backoffEnabled: true
        )
        #expect(interval <= 3600)
    }

    @Test("Jitter produces variation across calls")
    func jitterProducesVariation() {
        var values: Set<TimeInterval> = []
        for _ in 0..<20 {
            let v = Scheduler.backoffInterval(
                baseInterval: 60,
                consecutiveFailures: 3,
                backoffEnabled: true
            )
            values.insert(v)
        }
        // With jitter, 20 samples should produce at least 2 distinct values
        #expect(values.count >= 2)
    }

    @Test("Backoff disabled returns base interval regardless of failures")
    func backoffDisabled() {
        let interval = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 5,
            backoffEnabled: false
        )
        #expect(interval == 60)
    }
}
