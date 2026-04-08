import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("CrashTracker")
struct CrashTrackerTests {
    let tmpDir: URL

    init() {
        tmpDir = makeTempDir(prefix: "crash")
    }

    @Test("No crash detected on fresh start")
    func noCrashOnFreshStart() {
        let tracker = CrashTracker(stateDir: tmpDir)
        #expect(tracker.checkForCrash() == nil)
        cleanupTempDir(tmpDir)
    }

    @Test("Detects crash when running state file exists")
    func detectsCrash() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.markRunning(jobName: "bad-job")

        // Simulate daemon restart — new tracker reads state
        let tracker2 = CrashTracker(stateDir: tmpDir)
        #expect(tracker2.checkForCrash() == "bad-job")
        cleanupTempDir(tmpDir)
    }

    @Test("clearRunning removes state file")
    func clearRunning() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.markRunning(jobName: "ok-job")
        tracker.clearRunning()

        let tracker2 = CrashTracker(stateDir: tmpDir)
        #expect(tracker2.checkForCrash() == nil)
        cleanupTempDir(tmpDir)
    }

    @Test("Blacklists a crashed job")
    func blacklistsJob() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.blacklist(jobName: "crasher")

        #expect(tracker.isBlacklisted(jobName: "crasher"))
        #expect(!tracker.isBlacklisted(jobName: "other"))
        cleanupTempDir(tmpDir)
    }

    @Test("Blacklist persists across instances")
    func blacklistPersists() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.blacklist(jobName: "crasher")

        let tracker2 = CrashTracker(stateDir: tmpDir)
        #expect(tracker2.isBlacklisted(jobName: "crasher"))
        cleanupTempDir(tmpDir)
    }

    @Test("clearBlacklist removes a specific job")
    func clearBlacklist() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.blacklist(jobName: "job-a")
        tracker.blacklist(jobName: "job-b")

        tracker.clearBlacklist(jobName: "job-a")

        #expect(!tracker.isBlacklisted(jobName: "job-a"))
        #expect(tracker.isBlacklisted(jobName: "job-b"))
        cleanupTempDir(tmpDir)
    }

    @Test("crashedJobName returns name without clearing state")
    func crashedJobNameDoesNotClear() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.markRunning(jobName: "bad-job")

        let tracker2 = CrashTracker(stateDir: tmpDir)
        #expect(tracker2.crashedJobName() == "bad-job")

        // Should still be readable — not cleared
        let tracker3 = CrashTracker(stateDir: tmpDir)
        #expect(tracker3.crashedJobName() == "bad-job")
        cleanupTempDir(tmpDir)
    }

    @Test("crashedJobName returns nil on fresh start")
    func crashedJobNameNilOnFresh() {
        let tracker = CrashTracker(stateDir: tmpDir)
        #expect(tracker.crashedJobName() == nil)
        cleanupTempDir(tmpDir)
    }

    @Test("checkForCrash clears the running state")
    func checkClearsState() {
        let tracker = CrashTracker(stateDir: tmpDir)
        tracker.markRunning(jobName: "bad-job")

        let tracker2 = CrashTracker(stateDir: tmpDir)
        _ = tracker2.checkForCrash()

        // After checking, the state should be cleared
        let tracker3 = CrashTracker(stateDir: tmpDir)
        #expect(tracker3.checkForCrash() == nil)
        cleanupTempDir(tmpDir)
    }
}
