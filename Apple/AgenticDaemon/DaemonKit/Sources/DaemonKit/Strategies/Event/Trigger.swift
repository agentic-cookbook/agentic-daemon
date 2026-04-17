import Foundation

/// A source of "something happened, react now" signals for ``EventStrategy``.
///
/// ``EventStrategy`` owns the lifecycle — it reads this value, constructs
/// the appropriate underlying watcher at `start()` time, and tears it down
/// at `stop()`. Callers compose triggers declaratively.
public enum Trigger: Sendable {
    /// Watch a directory for filesystem changes. Fires when contents
    /// change (write/delete/rename), debounced by `debounceInterval`.
    case directory(URL, debounceInterval: TimeInterval = 0.3)

    /// A custom trigger: the caller supplies a start/stop pair and a
    /// callback the trigger fires whenever its condition is met.
    /// Useful for tests and non-filesystem event sources (timers,
    /// NSNotificationCenter, Mach ports, etc.).
    case custom(CustomTrigger)
}

/// A caller-supplied trigger. ``EventStrategy`` calls `start(fire:)` once,
/// passing in a closure the trigger should invoke each time its condition
/// fires, and calls `stop()` once when the strategy stops.
public struct CustomTrigger: Sendable {
    public let start: @Sendable (_ fire: @escaping @Sendable () -> Void) -> Void
    public let stop: @Sendable () -> Void

    public init(
        start: @escaping @Sendable (_ fire: @escaping @Sendable () -> Void) -> Void,
        stop: @escaping @Sendable () -> Void
    ) {
        self.start = start
        self.stop = stop
    }
}
