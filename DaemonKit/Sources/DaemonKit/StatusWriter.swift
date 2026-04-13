import Foundation
import os

/// Writes daemon status as JSON to a file. Useful for tooling and monitoring.
public struct StatusWriter: Sendable {
    private let logger: Logger
    private let statusURL: URL

    public init(statusURL: URL, subsystem: String) {
        self.logger = Logger(subsystem: subsystem, category: "StatusWriter")
        self.statusURL = statusURL
    }

    public func write<T: Encodable>(status: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(status) else {
            logger.error("Failed to encode status")
            return
        }

        try? data.write(to: statusURL, options: .atomic)
    }
}
