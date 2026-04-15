import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("JobLoader", .serialized)
struct JobLoaderTests {
    let compiler: SwiftCompiler
    let loader = JobLoader()
    let tmpDir: URL

    init() {
        tmpDir = makeTempDir(prefix: "loader")
        compiler = SwiftCompiler(buildDir: findBuildDir())
    }

    @Test("Loads compiled plugin and calls run()")
    func loadsAndRuns() throws {
        createJobDir(in: tmpDir, name: "simple", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "simple")
        try compiler.compile(job: descriptor)

        let request = JobRequest(
            jobName: "simple",
            jobDirectory: descriptor.directory,
            jobsDirectory: tmpDir,
            runReason: .scheduled,
            consecutiveFailures: 0
        )
        let response = try loader.load(descriptor: descriptor, request: request)

        // Default response from validJobSource()
        #expect(response.nextRunSeconds == nil)
        cleanupTempDir(tmpDir)
    }

    @Test("Plugin can return scheduling override")
    func returnsSchedulingOverride() throws {
        let source = """
        import Foundation
        import AgenticJobKit

        class Job: AgenticJob {
            override func run(request: JobRequest) throws -> JobResponse {
                return JobResponse(nextRunSeconds: 3600)
            }
        }
        """
        createJobDir(in: tmpDir, name: "scheduler", swiftSource: source)
        let descriptor = makeDescriptor(in: tmpDir, name: "scheduler")
        try compiler.compile(job: descriptor)

        let request = JobRequest(
            jobName: "scheduler",
            jobDirectory: descriptor.directory,
            jobsDirectory: tmpDir,
            runReason: .scheduled,
            consecutiveFailures: 0
        )
        let response = try loader.load(descriptor: descriptor, request: request)

        #expect(response.nextRunSeconds == 3600)
        cleanupTempDir(tmpDir)
    }

    @Test("Plugin can return trigger list")
    func returnsTriggerList() throws {
        let source = """
        import Foundation
        import AgenticJobKit

        class Job: AgenticJob {
            override func run(request: JobRequest) throws -> JobResponse {
                return JobResponse(trigger: ["downstream-a", "downstream-b"])
            }
        }
        """
        createJobDir(in: tmpDir, name: "trigger", swiftSource: source)
        let descriptor = makeDescriptor(in: tmpDir, name: "trigger")
        try compiler.compile(job: descriptor)

        let request = JobRequest(
            jobName: "trigger",
            jobDirectory: descriptor.directory,
            jobsDirectory: tmpDir,
            runReason: .scheduled,
            consecutiveFailures: 0
        )
        let response = try loader.load(descriptor: descriptor, request: request)

        #expect(response.trigger == ["downstream-a", "downstream-b"])
        cleanupTempDir(tmpDir)
    }

    @Test("Plugin receives correct request fields")
    func receivesRequestFields() throws {
        let source = """
        import Foundation
        import AgenticJobKit

        class Job: AgenticJob {
            override func run(request: JobRequest) throws -> JobResponse {
                // Verify we received the request by echoing in the message
                return JobResponse(
                    message: "name=\\(request.jobName) failures=\\(request.consecutiveFailures)"
                )
            }
        }
        """
        createJobDir(in: tmpDir, name: "echo", swiftSource: source)
        let descriptor = makeDescriptor(in: tmpDir, name: "echo")
        try compiler.compile(job: descriptor)

        let request = JobRequest(
            jobName: "echo",
            jobDirectory: descriptor.directory,
            jobsDirectory: tmpDir,
            runReason: .scheduled,
            consecutiveFailures: 5
        )
        let response = try loader.load(descriptor: descriptor, request: request)

        #expect(response.message == "name=echo failures=5")
        cleanupTempDir(tmpDir)
    }

    @Test("Throws for missing dylib")
    func throwsForMissingDylib() {
        createJobDir(in: tmpDir, name: "no-bin", swiftSource: validJobSource())
        let descriptor = makeDescriptor(in: tmpDir, name: "no-bin")
        // Don't compile — dylib doesn't exist

        let request = JobRequest(
            jobName: "no-bin",
            jobDirectory: descriptor.directory,
            jobsDirectory: tmpDir,
            runReason: .scheduled,
            consecutiveFailures: 0
        )

        var didThrow = false
        do {
            _ = try loader.load(descriptor: descriptor, request: request)
        } catch is JobLoadError {
            didThrow = true
        } catch {}
        #expect(didThrow)
        cleanupTempDir(tmpDir)
    }
}
