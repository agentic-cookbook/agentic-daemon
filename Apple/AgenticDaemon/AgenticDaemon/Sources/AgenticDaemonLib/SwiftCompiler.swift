import Foundation
import os

public struct SwiftCompiler: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "SwiftCompiler"
    )

    private let buildDir: URL

    /// moduleSearchPath: directory containing AgenticJobKit.swiftmodule
    var moduleSearchPath: String {
        buildDir.appending(path: "Modules").path(percentEncoded: false)
    }

    /// librarySearchPath: directory containing libAgenticJobKit.dylib
    var librarySearchPath: String {
        buildDir.path(percentEncoded: false)
    }

    public init(buildDir: URL) {
        self.buildDir = buildDir
    }

    public func needsCompile(job: JobDescriptor) -> Bool {
        let fm = FileManager.default
        let binaryPath = job.binaryURL.path(percentEncoded: false)

        guard fm.fileExists(atPath: binaryPath) else {
            return true
        }

        guard let sourceDate = modificationDate(of: job.sourceURL),
              let binaryDate = modificationDate(of: job.binaryURL) else {
            return true
        }

        return sourceDate > binaryDate
    }

    public func compile(job: JobDescriptor) throws {
        let name = job.name
        let moduleName = name.replacingOccurrences(of: "-", with: "_")

        logger.info("Compiling \(name) as plugin...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        process.arguments = [
            "-emit-library",
            "-parse-as-library",
            "-module-name", moduleName,
            "-I", moduleSearchPath,
            "-L", librarySearchPath,
            "-lAgenticJobKit",
            "-Xlinker", "-rpath", "-Xlinker", librarySearchPath,
            job.sourceURL.path(percentEncoded: false),
            "-o", job.binaryURL.path(percentEncoded: false)
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "(no output)"
            logger.error("Compile failed for \(name):\n\(errorOutput)")
            throw CompileError.failed(job: name, output: errorOutput)
        }

        logger.info("Compiled \(name) successfully")
    }

    /// Module name derived from job name (hyphens replaced with underscores).
    public static func moduleName(for jobName: String) -> String {
        jobName.replacingOccurrences(of: "-", with: "_")
    }

    private func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

public enum CompileError: Error {
    case failed(job: String, output: String)
}
