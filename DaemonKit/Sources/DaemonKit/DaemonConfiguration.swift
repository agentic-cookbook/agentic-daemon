import Foundation

/// Configuration for a DaemonEngine instance.
public struct DaemonConfiguration: Sendable {
    /// Reverse-DNS identifier for the daemon, e.g. "com.example.my-daemon".
    /// Used for logging subsystem and derived directory names.
    public let identifier: String

    /// Base directory for daemon state (crash reports, status file, blacklist, etc.).
    public let supportDirectory: URL

    /// Mach service name for the XPC server. Pass nil to disable XPC.
    public let machServiceName: String?

    /// Process name used to filter DiagnosticReports (.ips files).
    /// Defaults to the last component of `identifier`.
    public let crashReportProcessName: String

    /// How many days to retain crash reports. Default 30.
    public let crashRetentionDays: Int

    /// How often the scheduler tick fires, in seconds. Default 1.0.
    public let tickInterval: TimeInterval

    public init(
        identifier: String,
        supportDirectory: URL,
        machServiceName: String? = nil,
        crashReportProcessName: String? = nil,
        crashRetentionDays: Int = 30,
        tickInterval: TimeInterval = 1.0
    ) {
        self.identifier = identifier
        self.supportDirectory = supportDirectory
        self.machServiceName = machServiceName
        self.crashReportProcessName = crashReportProcessName ?? identifier.components(separatedBy: ".").last ?? identifier
        self.crashRetentionDays = crashRetentionDays
        self.tickInterval = tickInterval
    }

    /// Directory for crash report JSON files.
    public var crashesDirectory: URL {
        supportDirectory.appending(path: "crashes")
    }
}
