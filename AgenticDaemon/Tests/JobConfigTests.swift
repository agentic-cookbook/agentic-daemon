import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("JobConfig")
struct JobConfigTests {

    @Test("Decodes full JSON with all fields")
    func decodesFullJSON() throws {
        let json = """
        {
            "intervalSeconds": 120,
            "enabled": false,
            "timeout": 45,
            "runAtWake": false,
            "backoffOnFailure": false
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(JobConfig.self, from: json)

        #expect(config.intervalSeconds == 120)
        #expect(config.enabled == false)
        #expect(config.timeout == 45)
        #expect(config.runAtWake == false)
        #expect(config.backoffOnFailure == false)
    }

    @Test("Default values are correct")
    func defaultValues() {
        let config = JobConfig.default

        #expect(config.intervalSeconds == 60)
        #expect(config.enabled == true)
        #expect(config.timeout == 30)
        #expect(config.runAtWake == true)
        #expect(config.backoffOnFailure == true)
    }

    @Test("Round-trip encode/decode preserves values")
    func roundTrip() throws {
        let original = JobConfig(
            intervalSeconds: 300,
            enabled: false,
            timeout: 10,
            runAtWake: false,
            backoffOnFailure: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JobConfig.self, from: data)

        #expect(decoded.intervalSeconds == original.intervalSeconds)
        #expect(decoded.enabled == original.enabled)
        #expect(decoded.timeout == original.timeout)
        #expect(decoded.runAtWake == original.runAtWake)
        #expect(decoded.backoffOnFailure == original.backoffOnFailure)
    }

    @Test("Init with partial overrides uses defaults for rest")
    func partialInit() {
        let config = JobConfig(intervalSeconds: 120, timeout: 10)

        #expect(config.intervalSeconds == 120)
        #expect(config.enabled == true)
        #expect(config.timeout == 10)
        #expect(config.runAtWake == true)
        #expect(config.backoffOnFailure == true)
    }

    // MARK: - Input Validation

    @Test("Negative intervalSeconds is clamped to minimum")
    func negativeIntervalClamped() {
        let config = JobConfig(intervalSeconds: -10)
        #expect(config.intervalSeconds >= 1)
    }

    @Test("Zero intervalSeconds is clamped to minimum")
    func zeroIntervalClamped() {
        let config = JobConfig(intervalSeconds: 0)
        #expect(config.intervalSeconds >= 1)
    }

    @Test("Negative timeout is clamped to minimum")
    func negativeTimeoutClamped() {
        let config = JobConfig(timeout: -5)
        #expect(config.timeout >= 1)
    }

    @Test("Extremely large intervalSeconds is capped")
    func extremeIntervalCapped() {
        let config = JobConfig(intervalSeconds: 999_999)
        #expect(config.intervalSeconds <= 86400)
    }

    @Test("Extremely large timeout is capped")
    func extremeTimeoutCapped() {
        let config = JobConfig(timeout: 999_999)
        #expect(config.timeout <= 3600)
    }

    @Test("Decoded negative values are clamped")
    func decodedNegativesClamped() throws {
        let json = """
        {"intervalSeconds": -1, "enabled": true, "timeout": -1, "runAtWake": true, "backoffOnFailure": true}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(JobConfig.self, from: json)
        #expect(config.intervalSeconds >= 1)
        #expect(config.timeout >= 1)
    }
}
