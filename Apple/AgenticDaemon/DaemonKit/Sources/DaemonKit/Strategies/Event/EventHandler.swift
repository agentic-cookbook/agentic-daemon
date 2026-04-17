import Foundation

/// The worker plugged into an ``EventStrategy``.
///
/// `start`/`stop` mirror the strategy's lifecycle. `handleTrigger` is called
/// once per firing of the strategy's ``Trigger`` (post-debounce). Handlers
/// should be idempotent — triggers can coalesce several upstream events
/// into a single call, so the handler is responsible for scanning/processing
/// whatever it tracks (e.g. reading all files in a drop directory).
///
/// `snapshot` is optional — the default returns a workUnit representing the
/// handler itself with state `.idle`. Override to expose richer state
/// (items-processed counters, last-error, per-queue breakdowns).
public protocol EventHandler: Sendable {
    /// Called once, before the first trigger. Inject dependencies via the
    /// ``DaemonContext`` (e.g. analytics, crash tracker for blacklisting).
    func start(context: DaemonContext) async throws

    /// Called once at stop. Implementations must be idempotent — strategies
    /// may call through after a failed start.
    func stop() async

    /// Called once per trigger firing. If it throws, the strategy logs and
    /// continues — triggers keep firing. Use ``DaemonContext/crashTracker``
    /// captured at `start` if you want to blacklist after repeated failures.
    func handleTrigger() async throws

    /// Optional introspection hook. The default returns a single idle
    /// work unit named after the handler's type.
    func snapshot() async -> [WorkUnitSnapshot]
}

public extension EventHandler {
    func snapshot() async -> [WorkUnitSnapshot] {
        [WorkUnitSnapshot(name: String(describing: type(of: self)), state: .idle)]
    }
}
