import Testing
import Foundation
@testable import DaemonKit

@Suite("Backoff")
struct BackoffTests {

    @Test("No backoff when disabled")
    func noBackoffWhenDisabled() {
        let interval = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 5,
            backoffEnabled: false
        )
        #expect(interval == 60)
    }

    @Test("No backoff on zero failures")
    func noBackoffOnZeroFailures() {
        let interval = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 0,
            backoffEnabled: true
        )
        #expect(interval == 60)
    }

    @Test("Backoff increases with failures")
    func backoffIncreases() {
        let base = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 1,
            backoffEnabled: true
        )
        // With 1 failure: random in 60...120
        #expect(base >= 60)
        #expect(base <= 120)
    }

    @Test("Backoff caps at 1 hour")
    func backoffCapsAtOneHour() {
        let interval = Scheduler.backoffInterval(
            baseInterval: 60,
            consecutiveFailures: 20,
            backoffEnabled: true
        )
        #expect(interval <= 3600)
    }
}
