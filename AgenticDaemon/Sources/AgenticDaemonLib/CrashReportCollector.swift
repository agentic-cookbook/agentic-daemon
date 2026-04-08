import Foundation
import os
import CrashReporter

public struct CrashReportCollector: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "CrashReportCollector"
    )

    private let supportDirectory: URL
    private let diagnosticReportsDirectory: URL
    private let processName: String

    public init(
        supportDirectory: URL,
        diagnosticReportsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports"),
        processName: String = "agentic-daemon"
    ) {
        self.supportDirectory = supportDirectory
        self.diagnosticReportsDirectory = diagnosticReportsDirectory
        self.processName = processName
    }

    /// Install PLCrashReporter's signal/exception handlers.
    /// Call once at daemon startup, before any jobs run.
    public func installCrashHandler() throws {
        let config = PLCrashReporterConfig(
            signalHandlerType: .mach,
            symbolicationStrategy: []
        )
        guard let reporter = PLCrashReporter(configuration: config) else {
            logger.error("Failed to create PLCrashReporter")
            return
        }
        try reporter.enableAndReturnError()
        logger.info("PLCrashReporter handler installed")
    }

    public func collectPendingReports(crashedJobName: String) -> [CrashReport] {
        var reports: [CrashReport] = []

        if let plReport = collectPLCrashReport(crashedJobName: crashedJobName) {
            reports.append(plReport)
        }

        let ipsReports = collectDiagnosticReports(crashedJobName: crashedJobName)
        reports.append(contentsOf: ipsReports)

        return reports
    }

    /// Check for a pending PLCrashReporter report from a previous crash.
    /// Returns a parsed CrashReport if one exists, nil otherwise.
    /// Purges the pending report after collection.
    public func collectPLCrashReport(crashedJobName: String) -> CrashReport? {
        let config = PLCrashReporterConfig(
            signalHandlerType: .mach,
            symbolicationStrategy: []
        )
        guard let reporter = PLCrashReporter(configuration: config) else { return nil }

        guard reporter.hasPendingCrashReport() else { return nil }

        defer { reporter.purgePendingCrashReport() }

        guard let data = try? reporter.loadPendingCrashReportDataAndReturnError(),
              let plReport = try? PLCrashReport(data: data) else {
            logger.warning("Failed to load pending PLCrashReporter report")
            return nil
        }

        let signal = plReport.signalInfo?.name
        let exceptionType = plReport.machExceptionInfo != nil
            ? "EXC_\(plReport.machExceptionInfo.type)"
            : nil

        var stackFrames: [CrashReport.StackFrame]?
        if let crashedThread = plReport.threads?.first(where: { ($0 as? PLCrashReportThreadInfo)?.crashed == true }) as? PLCrashReportThreadInfo,
           let frames = crashedThread.stackFrames as? [PLCrashReportStackFrameInfo] {
            stackFrames = frames.map { frame in
                CrashReport.StackFrame(
                    symbol: frame.symbolInfo?.symbolName,
                    imageOffset: Int(frame.instructionPointer),
                    sourceFile: nil,
                    sourceLine: nil
                )
            }
        }

        logger.info("Collected PLCrashReporter report for job: \(crashedJobName)")

        return CrashReport(
            jobName: crashedJobName,
            timestamp: plReport.systemInfo?.timestamp ?? Date.now,
            signal: signal,
            exceptionType: exceptionType,
            faultingThread: nil,
            stackTrace: stackFrames,
            source: .plcrash
        )
    }

    func collectDiagnosticReports(crashedJobName: String) -> [CrashReport] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: diagnosticReportsDirectory.path(percentEncoded: false)) else {
            return []
        }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: diagnosticReportsDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            logger.warning("Could not read DiagnosticReports: \(error)")
            return []
        }

        let ipsFiles = contents.filter { $0.pathExtension == "ips" }
        var reports: [CrashReport] = []

        for file in ipsFiles {
            if let report = parseIPSFile(file, crashedJobName: crashedJobName) {
                reports.append(report)
            }
        }

        return reports
    }

    func parseIPSFile(_ url: URL, crashedJobName: String) -> CrashReport? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        // .ips format: line 1 is metadata JSON, remaining lines are crash report JSON
        let lines = content.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        // Parse metadata (line 1) to check process name
        guard let metadataData = lines[0].data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let appName = metadata["app_name"] as? String,
              appName == processName else {
            return nil
        }

        // Parse crash report (line 2+)
        let reportJSON = lines.dropFirst().joined(separator: "\n")
        guard let reportData = reportJSON.data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: reportData) as? [String: Any] else {
            return nil
        }

        let exception = report["exception"] as? [String: Any]
        let exceptionType = exception?["type"] as? String
        let signal = exception?["signal"] as? String
        let faultingThread = report["faultingThread"] as? Int

        // Extract stack frames from the faulting thread
        var stackFrames: [CrashReport.StackFrame]?
        if let threads = report["threads"] as? [[String: Any]] {
            // Find the triggered thread (the one that caused the crash)
            let crashThread = threads.first { ($0["triggered"] as? Bool) == true }
            if let frames = crashThread?["frames"] as? [[String: Any]] {
                stackFrames = frames.map { frame in
                    CrashReport.StackFrame(
                        symbol: frame["symbol"] as? String,
                        imageOffset: frame["imageOffset"] as? Int,
                        sourceFile: frame["sourceFile"] as? String,
                        sourceLine: frame["sourceLine"] as? Int
                    )
                }
            }
        }

        // Parse timestamp from metadata
        let timestampStr = metadata["timestamp"] as? String
        let timestamp = Self.parseIPSTimestamp(timestampStr) ?? Date.now

        return CrashReport(
            jobName: crashedJobName,
            timestamp: timestamp,
            signal: signal,
            exceptionType: exceptionType,
            faultingThread: faultingThread,
            stackTrace: stackFrames,
            source: .diagnosticReport
        )
    }

    private static func parseIPSTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)
    }
}
