import Foundation
import Testing
@testable import AgenticDaemonLib

@Suite("CrashReportCollector")
struct CrashReportCollectorTests {

    /// Minimal .ips file content matching real macOS format.
    /// Line 1: metadata JSON, Line 2+: crash report JSON.
    static func makeIPSContent(
        processName: String = "agentic-daemon",
        exceptionType: String = "EXC_CRASH",
        signal: String = "SIGABRT",
        faultingThread: Int = 3,
        timestamp: String = "2026-04-07 18:08:23.00 -0700"
    ) -> String {
        let metadata = """
        {"app_name":"\(processName)","timestamp":"\(timestamp)","bug_type":"309","os_version":"macOS 26.3.1","name":"\(processName)"}
        """
        let report = """
        {
          "procName": "\(processName)",
          "captureTime": "\(timestamp)",
          "exception": {
            "type": "\(exceptionType)",
            "signal": "\(signal)",
            "codes": "0x0, 0x0"
          },
          "faultingThread": \(faultingThread),
          "threads": [
            {"id": 1, "frames": []},
            {"id": 2, "frames": []},
            {"id": 3, "frames": []},
            {
              "id": 4,
              "triggered": true,
              "frames": [
                {
                  "symbol": "__pthread_kill",
                  "symbolLocation": 8,
                  "imageOffset": 38320
                },
                {
                  "symbol": "abort",
                  "symbolLocation": 124,
                  "imageOffset": 497744
                },
                {
                  "symbol": "JobRunner.run(job:)",
                  "symbolLocation": 4152,
                  "imageOffset": 85516,
                  "sourceFile": "JobRunner.swift",
                  "sourceLine": 47
                }
              ]
            }
          ]
        }
        """
        return metadata + "\n" + report
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ips-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Parses .ips file and extracts crash fields")
    func parsesIPSFile() throws {
        let diagDir = try Self.makeTempDir()
        let supportDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: diagDir)
            try? FileManager.default.removeItem(at: supportDir)
        }

        let ipsFile = diagDir.appending(path: "agentic-daemon-2026-04-07-180823.ips")
        try Self.makeIPSContent().write(to: ipsFile, atomically: true, encoding: .utf8)

        let collector = CrashReportCollector(
            supportDirectory: supportDir,
            diagnosticReportsDirectory: diagDir,
            processName: "agentic-daemon"
        )

        let reports = collector.collectPendingReports(crashedJobName: "test-job")

        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.jobName == "test-job")
        #expect(report.exceptionType == "EXC_CRASH")
        #expect(report.signal == "SIGABRT")
        #expect(report.faultingThread == 3)
        #expect(report.source == .diagnosticReport)
    }

    @Test("Extracts stack frames from faulting thread")
    func extractsStackFrames() throws {
        let diagDir = try Self.makeTempDir()
        let supportDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: diagDir)
            try? FileManager.default.removeItem(at: supportDir)
        }

        let ipsFile = diagDir.appending(path: "agentic-daemon-2026-04-07-180823.ips")
        try Self.makeIPSContent().write(to: ipsFile, atomically: true, encoding: .utf8)

        let collector = CrashReportCollector(
            supportDirectory: supportDir,
            diagnosticReportsDirectory: diagDir,
            processName: "agentic-daemon"
        )

        let reports = collector.collectPendingReports(crashedJobName: "test-job")
        let frames = try #require(reports.first?.stackTrace)

        #expect(frames.count == 3)
        #expect(frames[0].symbol == "__pthread_kill")
        #expect(frames[2].symbol == "JobRunner.run(job:)")
        #expect(frames[2].sourceFile == "JobRunner.swift")
        #expect(frames[2].sourceLine == 47)
    }

    @Test("Filters .ips files by process name")
    func filtersByProcessName() throws {
        let diagDir = try Self.makeTempDir()
        let supportDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: diagDir)
            try? FileManager.default.removeItem(at: supportDir)
        }

        // Our daemon crash
        let ours = diagDir.appending(path: "agentic-daemon-2026-04-07-180823.ips")
        try Self.makeIPSContent(processName: "agentic-daemon")
            .write(to: ours, atomically: true, encoding: .utf8)

        // Some other process crash
        let other = diagDir.appending(path: "Safari-2026-04-07-180823.ips")
        try Self.makeIPSContent(processName: "Safari")
            .write(to: other, atomically: true, encoding: .utf8)

        let collector = CrashReportCollector(
            supportDirectory: supportDir,
            diagnosticReportsDirectory: diagDir,
            processName: "agentic-daemon"
        )

        let reports = collector.collectPendingReports(crashedJobName: "test-job")
        #expect(reports.count == 1)
        #expect(reports[0].signal == "SIGABRT")
    }

    @Test("Handles malformed .ips gracefully")
    func handlesMalformedIPS() throws {
        let diagDir = try Self.makeTempDir()
        let supportDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: diagDir)
            try? FileManager.default.removeItem(at: supportDir)
        }

        let bad = diagDir.appending(path: "agentic-daemon-2026-04-07-180823.ips")
        try "not valid json at all".write(to: bad, atomically: true, encoding: .utf8)

        let collector = CrashReportCollector(
            supportDirectory: supportDir,
            diagnosticReportsDirectory: diagDir,
            processName: "agentic-daemon"
        )

        let reports = collector.collectPendingReports(crashedJobName: "test-job")
        #expect(reports.isEmpty)
    }

    @Test("Returns empty for non-existent diagnostics directory")
    func nonExistentDirectory() throws {
        let supportDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let collector = CrashReportCollector(
            supportDirectory: supportDir,
            diagnosticReportsDirectory: supportDir.appending(path: "does-not-exist"),
            processName: "agentic-daemon"
        )

        let reports = collector.collectPendingReports(crashedJobName: "test-job")
        #expect(reports.isEmpty)
    }

    @Test("Only picks up .ips files, ignores other extensions")
    func ignoresNonIPSFiles() throws {
        let diagDir = try Self.makeTempDir()
        let supportDir = try Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: diagDir)
            try? FileManager.default.removeItem(at: supportDir)
        }

        // .diag file with matching process name in content
        let diag = diagDir.appending(path: "agentic-daemon-2026-04-07-180823.diag")
        try Self.makeIPSContent(processName: "agentic-daemon")
            .write(to: diag, atomically: true, encoding: .utf8)

        let collector = CrashReportCollector(
            supportDirectory: supportDir,
            diagnosticReportsDirectory: diagDir,
            processName: "agentic-daemon"
        )

        let reports = collector.collectPendingReports(crashedJobName: "test-job")
        #expect(reports.isEmpty)
    }
}
