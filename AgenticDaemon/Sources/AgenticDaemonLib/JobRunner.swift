import Foundation
import os

public struct JobRunner: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "JobRunner"
    )

    public init() {}

    public func run(job: JobDescriptor) {
        let name = job.name
        let binaryPath = job.binaryURL.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            logger.error("No binary for \(name) at \(binaryPath)")
            return
        }

        logger.info("Running \(name)")

        let process = Process()
        process.executableURL = job.binaryURL
        process.currentDirectoryURL = job.directory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch \(name): \(error)")
            return
        }

        let timeout = job.config.timeout
        let timedOut = waitWithTimeout(process: process, seconds: timeout)

        if timedOut {
            process.terminate()
            logger.warning("Job \(name) timed out after \(timeout)s, terminated")
        }

        let exitCode = process.terminationStatus
        let stdout = readPipe(stdoutPipe)
        let stderr = readPipe(stderrPipe)

        if !stdout.isEmpty {
            logger.info("[\(name)] stdout: \(stdout)")
        }
        if !stderr.isEmpty {
            logger.warning("[\(name)] stderr: \(stderr)")
        }

        if exitCode == 0 {
            logger.info("Job \(name) completed (exit 0)")
        } else {
            logger.error("Job \(name) failed (exit \(exitCode))")
        }
    }

    private func waitWithTimeout(process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while process.isRunning {
            if Date.now >= deadline {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
