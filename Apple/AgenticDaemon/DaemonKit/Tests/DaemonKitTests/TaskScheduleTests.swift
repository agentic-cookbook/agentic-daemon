import Testing
import Foundation
@testable import DaemonKit

@Suite("TaskSchedule")
struct TaskScheduleTests {

    @Test("intervalSeconds clamps below minimum to 1")
    func intervalClampsMin() {
        let schedule = TaskSchedule(intervalSeconds: 0)
        #expect(schedule.intervalSeconds == 1)
    }

    @Test("intervalSeconds clamps above maximum to 86400")
    func intervalClampsMax() {
        let schedule = TaskSchedule(intervalSeconds: 100_000)
        #expect(schedule.intervalSeconds == 86400)
    }

    @Test("timeout clamps below minimum to 1")
    func timeoutClampsMin() {
        let schedule = TaskSchedule(timeout: 0)
        #expect(schedule.timeout == 1)
    }

    @Test("timeout clamps above maximum to 3600")
    func timeoutClampsMax() {
        let schedule = TaskSchedule(timeout: 5000)
        #expect(schedule.timeout == 3600)
    }

    @Test("default schedule has expected values")
    func defaultValues() {
        let schedule = TaskSchedule.default
        #expect(schedule.intervalSeconds == 60)
        #expect(schedule.enabled == true)
        #expect(schedule.timeout == 30)
        #expect(schedule.backoffOnFailure == true)
    }

    @Test("valid values pass through unclamped")
    func validValuesPassThrough() {
        let schedule = TaskSchedule(intervalSeconds: 120, enabled: false, timeout: 45, backoffOnFailure: false)
        #expect(schedule.intervalSeconds == 120)
        #expect(schedule.enabled == false)
        #expect(schedule.timeout == 45)
        #expect(schedule.backoffOnFailure == false)
    }
}
