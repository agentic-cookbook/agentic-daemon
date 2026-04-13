import Foundation
import os

public struct CrashReportStore: Sendable {
    private let logger: Logger
    private let crashesDirectory: URL

    public init(crashesDirectory: URL, subsystem: String) {
        self.logger = Logger(subsystem: subsystem, category: "CrashReportStore")
        self.crashesDirectory = crashesDirectory
    }

    public func save(_ report: CrashReport) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime]
        let timestamp = formatter.string(from: report.timestamp)
            .replacingOccurrences(of: ":", with: "")
        let filename = "crash-\(timestamp).json"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let fileURL = crashesDirectory.appending(path: filename)
        try data.write(to: fileURL, options: .atomic)

        logger.info("Saved crash report: \(filename)")
    }

    public func loadAll() -> [CrashReport] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: crashesDirectory, includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let report = try? decoder.decode(CrashReport.self, from: data) else {
                    return nil
                }
                return report
            }
    }

    public func cleanup(retentionDays: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: crashesDirectory, includingPropertiesForKeys: [.creationDateKey]
        ) else {
            return
        }

        let cutoff = Date.now.addingTimeInterval(-Double(retentionDays) * 86400)

        for file in files where file.pathExtension == "json" {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path(percentEncoded: false)),
                  let created = attrs[.creationDate] as? Date,
                  created < cutoff else {
                continue
            }
            try? fm.removeItem(at: file)
            logger.info("Cleaned up old crash report: \(file.lastPathComponent)")
        }
    }
}
