import Foundation

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
open class AgenticJob: NSObject {
    public required override init() {
        super.init()
    }

    open func run(request: JobRequest) throws -> JobResponse {
        fatalError("Subclasses must override run(request:)")
    }
}
