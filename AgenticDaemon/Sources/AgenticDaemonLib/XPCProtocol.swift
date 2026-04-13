import Foundation

@objc public protocol AgenticDaemonXPCProtocol {
    func healthCheck(reply: @escaping @Sendable (Data) -> Void)
    func listJobs(reply: @escaping @Sendable ([Data]) -> Void)
    func jobRuns(jobName: String, limit: Int, reply: @escaping @Sendable ([Data]) -> Void)
    func recentRuns(limit: Int, reply: @escaping @Sendable ([Data]) -> Void)
}
