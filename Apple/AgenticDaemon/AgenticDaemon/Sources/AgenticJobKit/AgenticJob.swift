import Foundation

/// ObjC-compatible protocol for cross-dylib casting.
/// The daemon uses this to invoke plugins regardless of Swift type identity.
@objc public protocol AgenticJobPlugin: NSObjectProtocol {
    init()
    func runJobWithData(_ data: Data) throws -> Data
}

/// Base class for all agentic-daemon job plugins.
///
/// Subclass this and override `run(request:)` to implement your job.
/// The class must be named `Job` for the daemon to discover it.
///
///     class Job: AgenticJob {
///         override func run(request: JobRequest) throws -> JobResponse {
///             // do work
///             return JobResponse(nextRunSeconds: 3600)
///         }
///     }
///
open class AgenticJob: NSObject, AgenticJobPlugin {
    public required override init() {
        super.init()
    }

    /// Override this method to implement your job logic.
    open func run(request: JobRequest) throws -> JobResponse {
        fatalError("Subclasses must override run(request:)")
    }

    /// ObjC bridge — decodes request, calls run(), encodes response.
    /// Used by the daemon's plugin loader. Job authors never call this.
    @objc public func runJobWithData(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(JobRequest.self, from: data)
        let response = try run(request: request)
        return try JSONEncoder().encode(response)
    }
}
