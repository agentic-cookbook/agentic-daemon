import Foundation
import os

/// A self-driving unit of work the daemon hosts.
///
/// Strategies encapsulate *when* work happens. A ``TimingStrategy`` drives
/// itself with a tick loop; an ``EventStrategy`` drives itself by reacting to
/// triggers. The engine never branches on strategy kind — it only calls
/// ``start(context:)``, ``stop()``, and ``snapshot()``. Compose multiple
/// strategies with ``CompositeStrategy``.
public protocol DaemonStrategy: Sendable {
    /// Human-readable identifier for this strategy instance. Used in logs and
    /// in ``StrategySnapshot``. Usually short, e.g. "timing" or "ingest".
    var name: String { get }

    /// Start the strategy. Called once, after crash processing, before the
    /// engine enters its shutdown wait. The strategy should kick off its own
    /// internal scheduling/watching and return promptly.
    func start(context: DaemonContext) async throws

    /// Stop the strategy. Called once, before the engine returns from
    /// ``DaemonEngine/run(xpcExportedObject:xpcInterface:httpRouter:)``.
    /// Implementations must be idempotent.
    func stop() async

    /// Lowest-common-denominator introspection. Consumers that need the
    /// strategy's rich domain API should downcast to the concrete type; this
    /// is for generic CLIs, menu bars, and `/health`-style endpoints.
    func snapshot() async -> StrategySnapshot
}

/// Shared infrastructure strategies receive at start time.
///
/// The engine builds one of these from its configuration and provides it to
/// each strategy's ``DaemonStrategy/start(context:)``. Strategies should
/// capture only what they need; the context itself is cheap to copy.
public struct DaemonContext: Sendable {
    /// Shared crash-tracking primitive. Each strategy decides what
    /// blacklisting means in its semantics.
    public let crashTracker: CrashTracker
    /// Analytics sink for work-unit lifecycle events.
    public let analytics: any AnalyticsProvider
    /// Logging subsystem string, e.g. `"com.agentic-cookbook.daemon"`.
    public let subsystem: String
    /// Writable support directory for any strategy-specific state.
    public let supportDirectory: URL

    public init(
        crashTracker: CrashTracker,
        analytics: any AnalyticsProvider,
        subsystem: String,
        supportDirectory: URL
    ) {
        self.crashTracker = crashTracker
        self.analytics = analytics
        self.subsystem = subsystem
        self.supportDirectory = supportDirectory
    }
}

/// A generic, strategy-agnostic view of a strategy's current state.
///
/// Rich per-strategy APIs (e.g. TimingStrategy's `scheduledTask(named:)`) are
/// the preferred surface for in-process consumers. ``StrategySnapshot`` is for
/// wire-level and UI consumers that want a uniform shape across strategies.
public struct StrategySnapshot: Sendable, Codable {
    public let name: String
    /// Canonical kind string: `"timing"`, `"event"`, `"composite"`, or a
    /// client-defined value. Consumers should treat unknown kinds as opaque.
    public let kind: String
    public let workUnits: [WorkUnitSnapshot]
    /// Child snapshots for composite strategies. Empty for leaf strategies.
    public let children: [StrategySnapshot]

    public init(
        name: String,
        kind: String,
        workUnits: [WorkUnitSnapshot],
        children: [StrategySnapshot] = []
    ) {
        self.name = name
        self.kind = kind
        self.workUnits = workUnits
        self.children = children
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        workUnits = try c.decode([WorkUnitSnapshot].self, forKey: .workUnits)
        children = try c.decodeIfPresent([StrategySnapshot].self, forKey: .children) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, workUnits, children
    }
}

/// A uniform view of a single unit of work within a strategy.
///
/// For timing strategies, a work unit is a scheduled task. For event
/// strategies, a work unit is typically a handler (or a trigger + handler
/// pair). Fields that don't apply to a given strategy are nil — e.g.
/// `nextActivation` is always nil for pure event-driven work units.
public struct WorkUnitSnapshot: Sendable, Codable {
    public let name: String
    public let state: WorkUnitState
    public let nextActivation: Date?
    public let consecutiveFailures: Int
    public let isBlacklisted: Bool
    public let lastMessage: String?

    public init(
        name: String,
        state: WorkUnitState,
        nextActivation: Date? = nil,
        consecutiveFailures: Int = 0,
        isBlacklisted: Bool = false,
        lastMessage: String? = nil
    ) {
        self.name = name
        self.state = state
        self.nextActivation = nextActivation
        self.consecutiveFailures = consecutiveFailures
        self.isBlacklisted = isBlacklisted
        self.lastMessage = lastMessage
    }

    /// Marked `@frozen` because DaemonKit uses `BUILD_LIBRARY_FOR_DISTRIBUTION`
    /// — without `@frozen`, switch statements on this enum require
    /// `@unknown default`, which we don't want for a closed, stable set
    /// of states.
    @frozen public enum WorkUnitState: String, Sendable, Codable {
        case idle
        case running
        case disabled
        case blacklisted
    }
}
