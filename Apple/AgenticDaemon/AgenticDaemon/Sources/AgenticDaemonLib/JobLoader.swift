import Foundation
import os
import AgenticJobKit

public enum JobLoadError: Error {
    case dylibNotFound(URL)
    case dlOpenFailed(String)
    case classNotFound(String)
    case castFailed(String)
}

public struct JobLoader: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "JobLoader"
    )

    public init() {}

    /// Loads a compiled job plugin and calls its run() method.
    ///
    /// - Opens the job's .dylib via dlopen
    /// - Finds the `Job` class via NSClassFromString (module-qualified)
    /// - Casts to AgenticJobPlugin (@objc protocol for cross-dylib safety)
    /// - Bridges request/response through Codable serialization
    public func load(descriptor: JobDescriptor, request: JobRequest) throws -> JobResponse {
        let dylibPath = descriptor.binaryURL.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            logger.error("No plugin dylib for \(descriptor.name) at \(dylibPath)")
            throw JobLoadError.dylibNotFound(descriptor.binaryURL)
        }

        let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL)
        guard handle != nil else {
            let error = String(cString: dlerror())
            logger.error("dlopen failed for \(descriptor.name): \(error)")
            throw JobLoadError.dlOpenFailed(error)
        }

        defer { dlclose(handle) }

        let moduleName = SwiftCompiler.moduleName(for: descriptor.name)
        let className = "\(moduleName).Job"

        guard let cls = NSClassFromString(className) else {
            logger.error("Class \(className) not found in \(descriptor.name)")
            throw JobLoadError.classNotFound(className)
        }

        guard let pluginClass = cls as? AgenticJobPlugin.Type else {
            logger.error("Class \(className) does not conform to AgenticJobPlugin")
            throw JobLoadError.castFailed(className)
        }

        let plugin = pluginClass.init()
        logger.info("Running plugin \(descriptor.name)")

        let requestData = try JSONEncoder().encode(request)
        let responseData = try plugin.runJobWithData(requestData)
        let response = try JSONDecoder().decode(JobResponse.self, from: responseData)

        if let message = response.message {
            logger.info("[\(descriptor.name)] \(message)")
        }

        return response
    }
}
