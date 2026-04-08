import Foundation
import os

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

    public func collectPendingReports(crashedJobName: String) -> [CrashReport] {
        var reports: [CrashReport] = []

        let ipsReports = collectDiagnosticReports(crashedJobName: crashedJobName)
        reports.append(contentsOf: ipsReports)

        return reports
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
