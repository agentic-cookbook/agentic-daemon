import Testing
import Foundation
@testable import DaemonKit

@Suite("CLIFormatters")
struct CLIFormatterTests {

    // MARK: - padRight

    @Test("padRight pads short string")
    func padRightPads() {
        #expect(padRight("hi", 10) == "hi        ")
    }

    @Test("padRight truncates long string")
    func padRightTruncates() {
        #expect(padRight("hello world", 6) == "hello…")
    }

    @Test("padRight handles exact width")
    func padRightExact() {
        #expect(padRight("abc", 3) == "abc")
    }

    // MARK: - formatDuration

    @Test("formatDuration under a minute")
    func durationSeconds() {
        #expect(formatDuration(42) == "42s")
    }

    @Test("formatDuration minutes")
    func durationMinutes() {
        #expect(formatDuration(125) == "2m 5s")
    }

    @Test("formatDuration hours")
    func durationHours() {
        #expect(formatDuration(3725) == "1h 2m")
    }

    // MARK: - formatTimestamp

    @Test("formatTimestamp with Date shows time")
    func timestampDate() {
        let date = Date()
        let result = formatTimestamp(date)
        // Today's date should be HH:mm:ss format (8 chars)
        #expect(result.count == 8)
    }
}
