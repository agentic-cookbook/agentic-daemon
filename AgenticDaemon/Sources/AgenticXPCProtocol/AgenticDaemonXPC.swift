import Foundation

/// XPC protocol between agentic-daemon and its menu bar companion.
/// Mach service name: com.agentic-cookbook.daemon.xpc
///
/// Complex types cross as JSON-encoded Data:
///   DaemonStatus  ← getDaemonStatus
///   [CrashReport] ← getCrashReports
@objc public protocol AgenticDaemonXPC {
    func getDaemonStatus(reply: @escaping (Data) -> Void)
    func getCrashReports(reply: @escaping (Data) -> Void)
    func enableJob(_ name: String, reply: @escaping (Bool) -> Void)
    func disableJob(_ name: String, reply: @escaping (Bool) -> Void)
    func triggerJob(_ name: String, reply: @escaping (Bool) -> Void)
    func clearBlacklist(_ name: String, reply: @escaping (Bool) -> Void)
    func shutdown(reply: @escaping () -> Void)
}
