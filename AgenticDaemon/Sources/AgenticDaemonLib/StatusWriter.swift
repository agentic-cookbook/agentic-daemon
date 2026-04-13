import Foundation
import os

public struct StatusWriter: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "StatusWriter"
    )
    private let statusURL: URL

    public init(statusURL: URL) {
        self.statusURL = statusURL
    }

    public func write(status: DaemonStatus) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(status)
            try data.write(to: statusURL, options: .atomic)
        } catch {
            logger.error("Failed to write status file: \(error)")
        }
    }
}
