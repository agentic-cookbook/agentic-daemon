import Foundation
import os

public struct CrashTracker: Sendable {
    private let logger: Logger
    private let runningFileURL: URL
    private let blacklistFileURL: URL

    public init(stateDir: URL, subsystem: String) {
        self.logger = Logger(subsystem: subsystem, category: "CrashTracker")
        self.runningFileURL = stateDir.appending(path: "running.txt")
        self.blacklistFileURL = stateDir.appending(path: "blacklist.json")
    }

    /// Write the name of the task about to run. If the daemon crashes,
    /// this file will still exist on next startup.
    public func markRunning(taskName: String) {
        try? taskName.write(to: runningFileURL, atomically: true, encoding: .utf8)
    }

    /// Clear the running marker after a task completes successfully.
    public func clearRunning() {
        try? FileManager.default.removeItem(at: runningFileURL)
    }

    /// Read the crashed task name without clearing the marker.
    /// Use this to pass the name to CrashReportCollector before
    /// calling checkForCrash() which clears it.
    public func crashedTaskName() -> String? {
        let path = runningFileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path),
              let name = try? String(contentsOf: runningFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// On startup, check if a running marker exists from a previous crash.
    /// Returns the task name that was running when the daemon died, or nil.
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

        logger.warning("Detected crash while running task: \(trimmed)")
        return trimmed
    }

    /// Add a task to the blacklist. It won't be loaded until cleared.
    public func blacklist(taskName: String) {
        var list = loadBlacklist()
        list.insert(taskName)
        saveBlacklist(list)
        logger.warning("Blacklisted task: \(taskName)")
    }

    /// Check if a task is blacklisted.
    public func isBlacklisted(taskName: String) -> Bool {
        loadBlacklist().contains(taskName)
    }

    /// Remove a task from the blacklist (e.g., when source changes).
    public func clearBlacklist(taskName: String) {
        var list = loadBlacklist()
        list.remove(taskName)
        saveBlacklist(list)
        logger.info("Cleared blacklist for: \(taskName)")
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
