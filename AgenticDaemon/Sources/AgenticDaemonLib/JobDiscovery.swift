import Foundation
import os

public struct JobDiscovery: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "JobDiscovery"
    )
    private let jobsDirectory: URL

    public init(jobsDirectory: URL) {
        self.jobsDirectory = jobsDirectory
    }

    public func discover() -> [JobDescriptor] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.error("Failed to list jobs directory")
            return []
        }

        var jobs: [JobDescriptor] = []

        for entry in entries {
            guard isDirectory(entry) else { continue }

            let sourceURL = entry.appending(path: "job.swift")
            guard fm.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
                logger.debug("Skipping \(entry.lastPathComponent): no job.swift")
                continue
            }

            let config = loadConfig(from: entry)
            let descriptor = JobDescriptor(
                name: entry.lastPathComponent,
                directory: entry,
                sourceURL: sourceURL,
                binaryURL: entry.appending(path: ".job-bin"),
                config: config
            )
            jobs.append(descriptor)
            logger.debug("Discovered job: \(descriptor.name)")
        }

        logger.info("Discovered \(jobs.count) job(s)")
        return jobs
    }

    private func loadConfig(from directory: URL) -> JobConfig {
        let configURL = directory.appending(path: "config.json")
        guard let data = try? Data(contentsOf: configURL) else {
            logger.debug("No config.json for \(directory.lastPathComponent), using defaults")
            return .default
        }
        do {
            return try JSONDecoder().decode(JobConfig.self, from: data)
        } catch {
            logger.error("Invalid config.json for \(directory.lastPathComponent): \(error)")
            return .default
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }
}
