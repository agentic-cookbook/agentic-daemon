import Foundation

/// XPC protocol between agentic-daemon and its menu bar companion.
/// Mach service name: com.agentic-cookbook.daemon.xpc
///
/// Complex types cross as JSON-encoded Data:
///   DaemonStatus  ← getDaemonStatus
///   [CrashReport] ← getCrashReports
///
/// Reply closures are @Sendable because NSXPCConnection invokes them from
/// arbitrary threads (cross-process IPC).
@objc public protocol AgenticDaemonXPC {
    func getDaemonStatus(reply: @escaping @Sendable (Data) -> Void)
    func getCrashReports(reply: @escaping @Sendable (Data) -> Void)
    func enableJob(_ name: String, reply: @escaping @Sendable (Bool) -> Void)
    func disableJob(_ name: String, reply: @escaping @Sendable (Bool) -> Void)
    func triggerJob(_ name: String, reply: @escaping @Sendable (Bool) -> Void)
    func clearBlacklist(_ name: String, reply: @escaping @Sendable (Bool) -> Void)
    func shutdown(reply: @escaping @Sendable () -> Void)
}
