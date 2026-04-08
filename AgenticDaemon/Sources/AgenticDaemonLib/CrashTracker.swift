import Foundation
import os

public struct CrashTracker: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "CrashTracker"
    )

    private let runningFileURL: URL
    private let blacklistFileURL: URL

    public init(stateDir: URL) {
        self.runningFileURL = stateDir.appending(path: "running.txt")
        self.blacklistFileURL = stateDir.appending(path: "blacklist.json")
    }

    /// Write the name of the job about to run. If the daemon crashes,
    /// this file will still exist on next startup.
    public func markRunning(jobName: String) {
        try? jobName.write(to: runningFileURL, atomically: true, encoding: .utf8)
    }

    /// Clear the running marker after a job completes successfully.
    public func clearRunning() {
        try? FileManager.default.removeItem(at: runningFileURL)
    }

    /// Read the crashed job name without clearing the marker.
    /// Use this to pass the name to CrashReportCollector before
    /// calling checkForCrash() which clears it.
    public func crashedJobName() -> String? {
        let path = runningFileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path),
              let name = try? String(contentsOf: runningFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// On startup, check if a running marker exists from a previous crash.
    /// Returns the job name that was running when the daemon died, or nil.
    /// Clears the marker after reading.
    public func checkForCrash() -> String? {
        let path = runningFileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path),
              let name = try? String(contentsOf: runningFileURL, encoding: .utf8) else {
            return nil
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        clearRunning()

        guard !trimmed.isEmpty else { return nil }

        logger.warning("Detected crash while running job: \(trimmed)")
        return trimmed
    }

    /// Add a job to the blacklist. It won't be loaded until cleared.
    public func blacklist(jobName: String) {
        var list = loadBlacklist()
        list.insert(jobName)
        saveBlacklist(list)
        logger.warning("Blacklisted job: \(jobName)")
    }

    /// Check if a job is blacklisted.
    public func isBlacklisted(jobName: String) -> Bool {
        loadBlacklist().contains(jobName)
    }

    /// Remove a job from the blacklist (e.g., when source changes).
    public func clearBlacklist(jobName: String) {
        var list = loadBlacklist()
        list.remove(jobName)
        saveBlacklist(list)
        logger.info("Cleared blacklist for: \(jobName)")
    }

    private func loadBlacklist() -> Set<String> {
        guard let data = try? Data(contentsOf: blacklistFileURL),
              let list = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return list
    }

    private func saveBlacklist(_ list: Set<String>) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: blacklistFileURL, options: .atomic)
    }
}
