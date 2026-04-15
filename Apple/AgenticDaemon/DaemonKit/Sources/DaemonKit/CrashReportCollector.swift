import Foundation
import os
@_implementationOnly import CrashReporter

public struct CrashReportCollector: Sendable {
    private let logger: Logger
    private let supportDirectory: URL
    private let diagnosticReportsDirectory: URL
    private let processName: String

    public init(
        supportDirectory: URL,
        processName: String,
        subsystem: String,
        diagnosticReportsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/DiagnosticReports")
    ) {
        self.logger = Logger(subsystem: subsystem, category: "CrashReportCollector")
        self.supportDirectory = supportDirectory
        self.processName = processName
        self.diagnosticReportsDirectory = diagnosticReportsDirectory
    }

    /// Install PLCrashReporter's signal/exception handlers.
    /// Call once at daemon startup, before any tasks run.
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

    public func collectPendingReports(crashedTaskName: String) -> [CrashReport] {
        var reports: [CrashReport] = []

        if let plReport = collectPLCrashReport(crashedTaskName: crashedTaskName) {
            reports.append(plReport)
        }

        let ipsReports = collectDiagnosticReports(crashedTaskName: crashedTaskName)
        reports.append(contentsOf: ipsReports)

        return reports
    }

    /// Check for a pending PLCrashReporter report from a previous crash.
    /// Returns a parsed CrashReport if one exists, nil otherwise.
    /// Purges the pending report after collection.
    public func collectPLCrashReport(crashedTaskName: String) -> CrashReport? {
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

        logger.info("Collected PLCrashReporter report for task: \(crashedTaskName)")

        return CrashReport(
            taskName: crashedTaskName,
            timestamp: plReport.systemInfo?.timestamp ?? Date.now,
            signal: signal,
            exceptionType: exceptionType,
            faultingThread: nil,
            stackTrace: stackFrames,
            source: .plcrash
        )
    }

    func collectDiagnosticReports(crashedTaskName: String) -> [CrashReport] {
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

        return contents
            .filter { $0.pathExtension == "ips" }
            .compactMap { parseIPSFile($0, crashedTaskName: crashedTaskName) }
    }

    func parseIPSFile(_ url: URL, crashedTaskName: String) -> CrashReport? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let lines = content.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }

        guard let metadataData = lines[0].data(using: .utf8),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let appName = metadata["app_name"] as? String,
              appName == processName else {
            return nil
        }

        let reportJSON = lines.dropFirst().joined(separator: "\n")
        guard let reportData = reportJSON.data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: reportData) as? [String: Any] else {
            return nil
        }

        let exception = report["exception"] as? [String: Any]
        let exceptionType = exception?["type"] as? String
        let signal = exception?["signal"] as? String
        let faultingThread = report["faultingThread"] as? Int

        var stackFrames: [CrashReport.StackFrame]?
        if let threads = report["threads"] as? [[String: Any]] {
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

        let timestampStr = metadata["timestamp"] as? String
        let timestamp = Self.parseIPSTimestamp(timestampStr) ?? Date.now

        return CrashReport(
            taskName: crashedTaskName,
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
