import Testing
import Foundation
@testable import DaemonKit

@Suite("DaemonConfiguration")
struct DaemonConfigurationTests {

    @Test("crashReportProcessName defaults to last identifier component")
    func processNameDefaultsToLastComponent() {
        let config = DaemonConfiguration(
            identifier: "com.example.my-daemon",
            supportDirectory: URL(fileURLWithPath: "/tmp/test")
        )
        #expect(config.crashReportProcessName == "my-daemon")
    }

    @Test("crashReportProcessName uses explicit value when provided")
    func processNameExplicit() {
        let config = DaemonConfiguration(
            identifier: "com.example.my-daemon",
            supportDirectory: URL(fileURLWithPath: "/tmp/test"),
            crashReportProcessName: "custom-name"
        )
        #expect(config.crashReportProcessName == "custom-name")
    }

    @Test("crashReportProcessName falls back to full identifier when no dots")
    func processNameFallbackNoDots() {
        let config = DaemonConfiguration(
            identifier: "daemon",
            supportDirectory: URL(fileURLWithPath: "/tmp/test")
        )
        #expect(config.crashReportProcessName == "daemon")
    }

    @Test("crashesDirectory is supportDirectory/crashes")
    func crashesDirectory() {
        let base = URL(fileURLWithPath: "/tmp/test-support")
        let config = DaemonConfiguration(
            identifier: "com.example.test",
            supportDirectory: base
        )
        #expect(config.crashesDirectory.lastPathComponent == "crashes")
        #expect(config.crashesDirectory.deletingLastPathComponent().path == base.path)
    }

    @Test("defaults are applied")
    func defaults() {
        let config = DaemonConfiguration(
            identifier: "com.example.test",
            supportDirectory: URL(fileURLWithPath: "/tmp/test")
        )
        #expect(config.machServiceName == nil)
        #expect(config.crashRetentionDays == 30)
        #expect(config.tickInterval == 1.0)
        #expect(config.httpPort == nil)
    }

    @Test("httpPort stores explicit value")
    func httpPortExplicit() {
        let config = DaemonConfiguration(
            identifier: "com.example.test",
            supportDirectory: URL(fileURLWithPath: "/tmp/test"),
            httpPort: 8080
        )
        #expect(config.httpPort == 8080)
    }
}
