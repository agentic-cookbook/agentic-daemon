import Testing
import Foundation
@testable import DaemonKit

// MARK: - Test doubles

private final class CountingHandler: EventHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _handleCount = 0
    private var _startCount = 0
    private var _stopCount = 0
    private var _shouldThrowOnStart = false
    private var _shouldThrowOnHandle = false
    private var _handleDelay: TimeInterval = 0

    var handleCount: Int { lock.withLock { _handleCount } }
    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    func setThrowOnStart(_ value: Bool) { lock.withLock { _shouldThrowOnStart = value } }
    func setThrowOnHandle(_ value: Bool) { lock.withLock { _shouldThrowOnHandle = value } }
    func setHandleDelay(_ value: TimeInterval) { lock.withLock { _handleDelay = value } }

    func start(context: DaemonContext) async throws {
        lock.withLock { _startCount += 1 }
        if lock.withLock({ _shouldThrowOnStart }) {
            throw NSError(domain: "test.handler.start", code: 1)
        }
    }

    func stop() async {
        lock.withLock { _stopCount += 1 }
    }

    func handleTrigger() async throws {
        let delay = lock.withLock { _handleDelay }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        lock.withLock { _handleCount += 1 }
        if lock.withLock({ _shouldThrowOnHandle }) {
            throw NSError(domain: "test.handler.handle", code: 2)
        }
    }
}

private func makeContext(in tmp: URL) -> (DaemonContext, CrashTracker, RecordingAnalytics) {
    let tracker = CrashTracker(stateDir: tmp, subsystem: "event.test")
    let analytics = RecordingAnalytics()
    let context = DaemonContext(
        crashTracker: tracker,
        analytics: analytics,
        subsystem: "event.test",
        supportDirectory: tmp
    )
    return (context, tracker, analytics)
}

private func makeTempDir(prefix: String = "event") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tests

@Suite("EventStrategy", .serialized)
struct EventStrategyTests {

    @Test("start calls handler.start")
    func startCallsHandlerStart() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        let (fire, trigger) = makeManualTrigger()
        let strategy = EventStrategy(name: "test", trigger: .custom(trigger), handler: handler)
        let (ctx, _, _) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        defer { Task { await strategy.stop() } }
        _ = fire // keep alive

        #expect(handler.startCount == 1)
    }

    @Test("start is idempotent")
    func startIdempotent() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        let (_, trigger) = makeManualTrigger()
        let strategy = EventStrategy(trigger: .custom(trigger), handler: handler)
        let (ctx, _, _) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        try await strategy.start(context: ctx)
        defer { Task { await strategy.stop() } }

        #expect(handler.startCount == 1)
    }

    @Test("start propagates handler errors")
    func startPropagatesError() async {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        handler.setThrowOnStart(true)
        let (_, trigger) = makeManualTrigger()
        let strategy = EventStrategy(trigger: .custom(trigger), handler: handler)
        let (ctx, _, _) = makeContext(in: tmp)

        await #expect(throws: (any Error).self) {
            try await strategy.start(context: ctx)
        }
        // Handler's stop should NOT be called when start failed
        #expect(handler.stopCount == 0)
    }

    @Test("custom trigger fires handler")
    func customTriggerFiresHandler() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        let (fire, trigger) = makeManualTrigger()
        let strategy = EventStrategy(trigger: .custom(trigger), handler: handler)
        let (ctx, _, _) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        defer { Task { await strategy.stop() } }

        fire()
        fire()
        fire()

        // Handler is called via Task.detached — poll until stable.
        var attempts = 0
        while handler.handleCount < 3 && attempts < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        #expect(handler.handleCount == 3)
    }

    @Test("directory trigger fires handler on file change")
    func directoryTriggerFires() async throws {
        let tmp = makeTempDir(prefix: "event-dir")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let watchDir = tmp.appending(path: "watched")
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)

        let handler = CountingHandler()
        let strategy = EventStrategy(
            trigger: .directory(watchDir, debounceInterval: 0.1),
            handler: handler
        )
        let (ctx, _, _) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        defer { Task { await strategy.stop() } }

        // Drop a file — should trigger after debounce
        let file = watchDir.appending(path: "event.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)

        var attempts = 0
        while handler.handleCount < 1 && attempts < 40 {
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
        #expect(handler.handleCount >= 1)
    }

    @Test("handler errors don't crash strategy; triggers keep firing")
    func handlerErrorsAreSwallowed() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        handler.setThrowOnHandle(true)
        let (fire, trigger) = makeManualTrigger()
        let strategy = EventStrategy(trigger: .custom(trigger), handler: handler)
        let (ctx, _, analytics) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        defer { Task { await strategy.stop() } }

        fire()
        fire()

        var attempts = 0
        while handler.handleCount < 2 && attempts < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        #expect(handler.handleCount == 2)

        // Failures are tracked in analytics, not propagated
        let failCount = analytics.events.filter { $0.kind == .taskFailed }.count
        #expect(failCount == 2)
    }

    @Test("analytics records taskStarted and taskCompleted for each trigger")
    func analyticsRecordsLifecycle() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        let (fire, trigger) = makeManualTrigger()
        let strategy = EventStrategy(name: "tracked", trigger: .custom(trigger), handler: handler)
        let (ctx, _, analytics) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        defer { Task { await strategy.stop() } }

        fire()

        var attempts = 0
        while handler.handleCount < 1 && attempts < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        // Allow analytics events to flush
        try? await Task.sleep(for: .milliseconds(50))

        let startedCount = analytics.events.filter {
            $0.kind == .taskStarted && ($0.properties["name"] as? String) == "tracked"
        }.count
        let completedCount = analytics.events.filter {
            $0.kind == .taskCompleted && ($0.properties["name"] as? String) == "tracked"
        }.count
        #expect(startedCount == 1)
        #expect(completedCount == 1)
    }

    @Test("stop calls handler.stop and halts further triggers")
    func stopHaltsTriggers() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        let (fire, trigger) = makeManualTrigger()
        let strategy = EventStrategy(trigger: .custom(trigger), handler: handler)
        let (ctx, _, _) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        fire()

        var attempts = 0
        while handler.handleCount < 1 && attempts < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        #expect(handler.handleCount == 1)

        await strategy.stop()
        #expect(handler.stopCount == 1)

        // Fires after stop should not reach the handler
        let beforeMore = handler.handleCount
        fire()
        fire()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(handler.handleCount == beforeMore)
    }

    @Test("stop is idempotent")
    func stopIdempotent() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let handler = CountingHandler()
        let (_, trigger) = makeManualTrigger()
        let strategy = EventStrategy(trigger: .custom(trigger), handler: handler)
        let (ctx, _, _) = makeContext(in: tmp)

        try await strategy.start(context: ctx)
        await strategy.stop()
        await strategy.stop()

        #expect(handler.stopCount == 1)
    }

    @Test("snapshot delegates to handler")
    func snapshotDelegatesToHandler() async {
        let handler = CountingHandler()
        let (_, trigger) = makeManualTrigger()
        let strategy = EventStrategy(name: "delegate", trigger: .custom(trigger), handler: handler)

        let snap = await strategy.snapshot()
        #expect(snap.name == "delegate")
        #expect(snap.kind == "event")
        // Default EventHandler snapshot returns one idle work unit
        #expect(snap.workUnits.count == 1)
        #expect(snap.workUnits.first?.state == .idle)
    }
}

// MARK: - Manual trigger helper

/// Returns (fire, trigger): call `fire()` to synchronously emit a trigger event.
private func makeManualTrigger() -> (@Sendable () -> Void, CustomTrigger) {
    let state = ManualTriggerState()
    let trigger = CustomTrigger(
        start: { fire in state.setCallback(fire) },
        stop: { state.setCallback(nil) }
    )
    let fire: @Sendable () -> Void = { state.invoke() }
    return (fire, trigger)
}

private final class ManualTriggerState: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func setCallback(_ cb: (@Sendable () -> Void)?) { lock.withLock { callback = cb } }
    func invoke() {
        let cb = lock.withLock { callback }
        cb?()
    }
}
