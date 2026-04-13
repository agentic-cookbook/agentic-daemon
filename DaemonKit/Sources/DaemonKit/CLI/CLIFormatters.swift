import Foundation

/// Pad or truncate a string to a fixed width. Strings longer than `width`
/// are truncated with an ellipsis.
public func padRight(_ s: String, _ width: Int) -> String {
    guard width > 0 else { return "" }
    if s.count > width {
        return String(s.prefix(width - 1)) + "…"
    }
    return s.padding(toLength: width, withPad: " ", startingAt: 0)
}

/// Format seconds as "42s", "3m 12s", or "2h 15m".
public func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}

/// Format a Date for terminal display.
/// Today → "HH:mm:ss", older → "MM-dd HH:mm:ss".
public func formatTimestamp(_ date: Date) -> String {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MM-dd HH:mm:ss"
    return fmt.string(from: date)
}

/// Format an ISO 8601 string for terminal display.
public func formatTimestamp(_ isoString: String) -> String {
    let parsers: [DateFormatter] = {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        iso.locale = Locale(identifier: "en_US_POSIX")
        let sqlite = DateFormatter()
        sqlite.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sqlite.locale = Locale(identifier: "en_US_POSIX")
        return [iso, sqlite]
    }()

    for parser in parsers {
        if let date = parser.date(from: isoString) {
            return formatTimestamp(date)
        }
    }
    return String(isoString.prefix(19))
}

/// Print an Encodable value as pretty-printed JSON to stdout.
public func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

/// Print error to stderr and exit.
public func die(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}
