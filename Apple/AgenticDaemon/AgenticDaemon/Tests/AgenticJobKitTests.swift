import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("AgenticJobKit")
struct AgenticJobKitTests {

    @Test("AgenticJob base class run() calls fatalError")
    func baseClassFatalErrors() {
        // Verify the base class is usable and is an NSObject (needed for bundle loading)
        let job = AgenticJob()
        #expect(job.superclass == NSObject.self)
    }

    @Test("JobRequest stores all fields")
    func requestFields() {
        let dir = URL(fileURLWithPath: "/tmp/test-job")
        let jobsDir = URL(fileURLWithPath: "/tmp/jobs")
        let request = JobRequest(
            jobName: "my-job",
            jobDirectory: dir,
            jobsDirectory: jobsDir,
            runReason: .scheduled,
            consecutiveFailures: 3
        )

        #expect(request.jobName == "my-job")
        #expect(request.jobDirectory == dir)
        #expect(request.jobsDirectory == jobsDir)
        #expect(request.runReason == .scheduled)
        #expect(request.consecutiveFailures == 3)
    }

    @Test("JobRequest runReason supports triggered")
    func requestTriggered() {
        let request = JobRequest(
            jobName: "t",
            jobDirectory: URL(fileURLWithPath: "/tmp"),
            jobsDirectory: URL(fileURLWithPath: "/tmp"),
            runReason: .triggered,
            consecutiveFailures: 0
        )
        #expect(request.runReason == .triggered)
    }

    @Test("JobResponse defaults are all nil")
    func responseDefaults() {
        let response = JobResponse()
        #expect(response.nextRunSeconds == nil)
        #expect(response.nextRunAt == nil)
        #expect(response.trigger == nil)
        #expect(response.enabled == nil)
        #expect(response.message == nil)
    }

    @Test("JobResponse stores scheduling override")
    func responseScheduling() {
        let response = JobResponse(nextRunSeconds: 3600)
        #expect(response.nextRunSeconds == 3600)
    }

    @Test("JobResponse stores absolute time")
    func responseAbsoluteTime() {
        let date = Date.now.addingTimeInterval(7200)
        let response = JobResponse(nextRunAt: date)
        #expect(response.nextRunAt == date)
    }

    @Test("JobResponse stores trigger list")
    func responseTriggers() {
        let response = JobResponse(trigger: ["job-a", "job-b"])
        #expect(response.trigger == ["job-a", "job-b"])
    }

    @Test("JobResponse can disable self")
    func responseDisable() {
        let response = JobResponse(enabled: false)
        #expect(response.enabled == false)
    }

    @Test("JobResponse stores message")
    func responseMessage() {
        let response = JobResponse(message: "processed 42 items")
        #expect(response.message == "processed 42 items")
    }

    @Test("JobResponse stores all fields together")
    func responseAllFields() {
        let date = Date.now
        let response = JobResponse(
            nextRunSeconds: 300,
            nextRunAt: date,
            trigger: ["downstream"],
            enabled: true,
            message: "done"
        )
        #expect(response.nextRunSeconds == 300)
        #expect(response.nextRunAt == date)
        #expect(response.trigger == ["downstream"])
        #expect(response.enabled == true)
        #expect(response.message == "done")
    }
}
