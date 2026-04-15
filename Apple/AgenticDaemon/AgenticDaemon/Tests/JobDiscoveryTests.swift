import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("JobDiscovery")
struct JobDiscoveryTests {
    let tmpDir: URL

    init() {
        tmpDir = makeTempDir(prefix: "discovery")
    }

    @Test("Discovers job directory containing job.swift")
    func discoversJob() {
        createJobDir(in: tmpDir, name: "my-job")
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()

        #expect(jobs.count == 1)
        #expect(jobs.first?.name == "my-job")
        cleanupTempDir(tmpDir)
    }

    @Test("Skips directories without job.swift")
    func skipsNoSource() {
        createJobDir(in: tmpDir, name: "no-source", swiftSource: nil)
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()

        #expect(jobs.isEmpty)
        cleanupTempDir(tmpDir)
    }

    @Test("Reads config.json when present")
    func readsConfig() {
        let config = """
        {"intervalSeconds": 300, "enabled": true, "timeout": 15, "runAtWake": false, "backoffOnFailure": true}
        """
        createJobDir(in: tmpDir, name: "configured", configJSON: config)
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()

        #expect(jobs.first?.config.intervalSeconds == 300)
        #expect(jobs.first?.config.timeout == 15)
        #expect(jobs.first?.config.runAtWake == false)
        cleanupTempDir(tmpDir)
    }

    @Test("Uses default config when config.json missing")
    func defaultsWhenMissing() {
        createJobDir(in: tmpDir, name: "no-config", configJSON: nil)
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()

        #expect(jobs.first?.config.intervalSeconds == 60)
        #expect(jobs.first?.config.enabled == true)
        cleanupTempDir(tmpDir)
    }

    @Test("Uses default config when config.json is invalid")
    func defaultsWhenInvalid() {
        createJobDir(in: tmpDir, name: "bad-config", configJSON: "not json {{{")
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()

        #expect(jobs.first?.config.intervalSeconds == 60)
        cleanupTempDir(tmpDir)
    }

    @Test("Returns empty array for empty directory")
    func emptyDirectory() {
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()

        #expect(jobs.isEmpty)
        cleanupTempDir(tmpDir)
    }

    @Test("Sets correct sourceURL and binaryURL paths")
    func correctPaths() {
        createJobDir(in: tmpDir, name: "path-test")
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()
        let job = jobs.first!

        #expect(job.sourceURL.lastPathComponent == "job.swift")
        #expect(job.binaryURL.lastPathComponent == "libpath_test.dylib")
        #expect(job.directory.lastPathComponent == "path-test")
        cleanupTempDir(tmpDir)
    }

    @Test("Discovers multiple jobs")
    func multipleJobs() {
        createJobDir(in: tmpDir, name: "job-a")
        createJobDir(in: tmpDir, name: "job-b")
        createJobDir(in: tmpDir, name: "job-c")
        let discovery = JobDiscovery(jobsDirectory: tmpDir)

        let jobs = discovery.discover()
        let names = Set(jobs.map(\.name))

        #expect(jobs.count == 3)
        #expect(names == ["job-a", "job-b", "job-c"])
        cleanupTempDir(tmpDir)
    }
}
