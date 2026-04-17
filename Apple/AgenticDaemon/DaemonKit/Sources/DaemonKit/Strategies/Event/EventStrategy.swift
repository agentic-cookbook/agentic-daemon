import Foundation
import os

/// A ``DaemonStrategy`` driven by a ``Trigger`` rather than a clock.
///
/// Wires a trigger to an ``EventHandler``: each time the trigger fires,
/// the strategy calls `handler.handleTrigger()`. There's no tick loop —
/// the strategy's work rate matches the trigger's firing rate.
///
///     let strategy = EventStrategy(
///         name: "ingest",
///         trigger: .directory(dropDir, debounceInterval: 0.3),
///         handler: MyIngestionHandler(db: db)
///     )
///
/// ``EventStrategy`` swallows handler errors (logs + analytics) and keeps
/// running — triggers are expected to keep arriving. If a handler crashes
/// the daemon, the crash-tracker blacklisting semantics are up to the
/// handler (it holds the tracker from ``DaemonContext``).
public final class EventStrategy: DaemonStrategy, @unchecked Sendable {
    public let name: String

    private let trigger: Trigger
    private let handler: any EventHandler

    /// Optional SSE broadcaster. When set, the strategy's `/events/stream`
    /// HTTP endpoint (via ``StrategyHTTPEndpoints``) upgrades connections
    /// to this broadcaster. Nil disables the endpoint.
    public let broadcaster: SSEBroadcaster?

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var running: Bool = false
        var watcher: DirectoryWatcher?
        var customStop: (@Sendable () -> Void)?
        var logger: Logger?
        var analytics: (any AnalyticsProvider)?
        var inflight: Int = 0
    }

    public init(
        name: String = "event",
        trigger: Trigger,
        handler: any EventHandler,
        broadcaster: SSEBroadcaster? = nil
    ) {
        self.name = name
        self.trigger = trigger
        self.handler = handler
        self.broadcaster = broadcaster
    }

    public func start(context: DaemonContext) async throws {
        let logger = Logger(subsystem: context.subsystem, category: "EventStrategy")

        let shouldStart = state.withLock { s -> Bool in
            guard !s.running else { return false }
            s.running = true
            s.logger = logger
            s.analytics = context.analytics
            return true
        }
        guard shouldStart else {
            logger.debug("EventStrategy \"\(self.name)\" start ignored — already running")
            return
        }

        do {
            try await handler.start(context: context)
        } catch {
            state.withLock { $0.running = false }
            logger.error("EventStrategy \"\(self.name)\" handler failed to start: \(error)")
            throw error
        }

        let fire: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            Task.detached(priority: .utility) { [weak self] in
                await self?.fire()
            }
        }

        switch trigger {
        case .directory(let url, let debounce):
            let watcher = DirectoryWatcher(
                directory: url,
                subsystem: context.subsystem,
                debounceInterval: debounce,
                onChange: fire
            )
            watcher.start()
            state.withLock { $0.watcher = watcher }
        case .custom(let custom):
            custom.start(fire)
            state.withLock { $0.customStop = custom.stop }
        }

        logger.info("EventStrategy \"\(self.name)\" started")
    }

    public func stop() async {
        let (wasRunning, watcher, customStop, logger) = state.withLock { s -> (Bool, DirectoryWatcher?, (@Sendable () -> Void)?, Logger?) in
            guard s.running else { return (false, nil, nil, s.logger) }
            s.running = false
            let result = (true, s.watcher, s.customStop, s.logger)
            s.watcher = nil
            s.customStop = nil
            return result
        }
        guard wasRunning else { return }

        watcher?.stop()
        customStop?()
        await handler.stop()
        logger?.info("EventStrategy \"\(self.name)\" stopped")
    }

    public func snapshot() async -> StrategySnapshot {
        let units = await handler.snapshot()
        return StrategySnapshot(name: name, kind: Self.kind, workUnits: units)
    }

    public static let kind = "event"

    // MARK: - Test / introspection hooks

    /// Number of trigger firings currently being processed. Exposed for
    /// tests that need to wait for in-flight work to drain.
    public var inflightCount: Int {
        state.withLock { $0.inflight }
    }

    // MARK: - Private

    private func fire() async {
        guard state.withLock({ $0.running }) else { return }

        let (logger, analytics) = state.withLock { ($0.logger, $0.analytics) }
        state.withLock { $0.inflight += 1 }
        defer { state.withLock { $0.inflight -= 1 } }

        analytics?.track(.taskStarted(name: name))
        let started = Date.now
        do {
            try await handler.handleTrigger()
            analytics?.track(.taskCompleted(
                name: name,
                durationSeconds: Date.now.timeIntervalSince(started)
            ))
        } catch {
            logger?.error("EventStrategy \"\(self.name)\" handler error: \(error)")
            analytics?.track(.taskFailed(
                name: name,
                durationSeconds: Date.now.timeIntervalSince(started)
            ))
        }
    }
}
