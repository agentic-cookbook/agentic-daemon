import Testing
import Foundation
@testable import DaemonKit

// MARK: - Test doubles

private final class RecordingStrategy: DaemonStrategy, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _throwOnStart = false
    private var _startDelay: TimeInterval = 0
    private var _snapshotUnits: [WorkUnitSnapshot]

    init(
        name: String,
        throwOnStart: Bool = false,
        snapshotUnits: [WorkUnitSnapshot] = []
    ) {
        self.name = name
        self._throwOnStart = throwOnStart
        self._snapshotUnits = snapshotUnits
    }

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    func setStartDelay(_ v: TimeInterval) { lock.withLock { _startDelay = v } }

    func start(context: DaemonContext) async throws {
        let delay = lock.withLock { _startDelay }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        lock.withLock { _startCount += 1 }
        if lock.withLock({ _throwOnStart }) {
            throw NSError(domain: "test.strategy", code: 99)
        }
    }

    func stop() async {
        lock.withLock { _stopCount += 1 }
    }

    func snapshot() async -> StrategySnapshot {
        let units = lock.withLock { _snapshotUnits }
        return StrategySnapshot(name: name, kind: "recording", workUnits: units)
    }
}

private func makeContext(in tmp: URL) -> DaemonContext {
    let tracker = CrashTracker(stateDir: tmp, subsystem: "composite.test")
    let analytics = RecordingAnalytics()
    return DaemonContext(
        crashTracker: tracker,
        analytics: analytics,
        subsystem: "composite.test",
        supportDirectory: tmp
    )
}

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "composite-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tests

@Suite("CompositeStrategy", .serialized)
struct CompositeStrategyTests {

    @Test("start propagates to all children")
    func startPropagates() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = RecordingStrategy(name: "a")
        let b = RecordingStrategy(name: "b")
        let c = RecordingStrategy(name: "c")
        let composite = CompositeStrategy([a, b, c])

        try await composite.start(context: makeContext(in: tmp))

        #expect(a.startCount == 1)
        #expect(b.startCount == 1)
        #expect(c.startCount == 1)
    }

    @Test("stop propagates to all children in reverse order")
    func stopReverseOrder() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Sequence observer via NSLock captures order
        let order = LockIsolatedArray<String>([])
        let a = OrderedStrategy(name: "a", order: order)
        let b = OrderedStrategy(name: "b", order: order)
        let c = OrderedStrategy(name: "c", order: order)
        let composite = CompositeStrategy([a, b, c])

        try await composite.start(context: makeContext(in: tmp))
        await composite.stop()

        #expect(order.values == ["start:a", "start:b", "start:c", "stop:c", "stop:b", "stop:a"])
    }

    @Test("child start failure aborts and stops already-started children")
    func childStartFailureRollsBack() async {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = RecordingStrategy(name: "a")
        let b = RecordingStrategy(name: "b")
        let c = RecordingStrategy(name: "c", throwOnStart: true)
        let d = RecordingStrategy(name: "d")
        let composite = CompositeStrategy([a, b, c, d])

        await #expect(throws: (any Error).self) {
            try await composite.start(context: makeContext(in: tmp))
        }

        // a and b started and then stopped; c attempted start; d never touched
        #expect(a.startCount == 1)
        #expect(a.stopCount == 1)
        #expect(b.startCount == 1)
        #expect(b.stopCount == 1)
        #expect(c.startCount == 1)  // attempted
        #expect(c.stopCount == 0)   // didn't successfully start
        #expect(d.startCount == 0)
    }

    @Test("snapshot nests children")
    func snapshotNestsChildren() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = RecordingStrategy(name: "timer", snapshotUnits: [
            WorkUnitSnapshot(name: "job1", state: .idle)
        ])
        let b = RecordingStrategy(name: "ingest", snapshotUnits: [
            WorkUnitSnapshot(name: "handler", state: .running)
        ])
        let composite = CompositeStrategy(name: "outer", [a, b])

        let snap = await composite.snapshot()
        #expect(snap.name == "outer")
        #expect(snap.kind == "composite")
        #expect(snap.workUnits.isEmpty)
        #expect(snap.children.count == 2)
        #expect(snap.children[0].name == "timer")
        #expect(snap.children[0].workUnits.first?.name == "job1")
        #expect(snap.children[1].name == "ingest")
        #expect(snap.children[1].workUnits.first?.state == .running)
    }

    @Test("snapshot round-trips through Codable with nested children")
    func snapshotCodableRoundtrip() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = RecordingStrategy(name: "a", snapshotUnits: [
            WorkUnitSnapshot(name: "u1", state: .idle)
        ])
        let composite = CompositeStrategy([a])
        let snap = await composite.snapshot()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StrategySnapshot.self, from: data)

        #expect(decoded.kind == "composite")
        #expect(decoded.children.count == 1)
        #expect(decoded.children[0].name == "a")
        #expect(decoded.children[0].workUnits.first?.name == "u1")
    }

    @Test("snapshot of legacy (no children) payload decodes with empty children")
    func legacyDecode() throws {
        // Simulate a payload produced before the `children` field existed.
        let legacyJSON = """
        {"name":"leaf","kind":"timing","workUnits":[]}
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(StrategySnapshot.self, from: data)
        #expect(decoded.children.isEmpty)
    }

    @Test("nested composite snapshots are preserved")
    func nestedComposites() async throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inner = CompositeStrategy(name: "inner", [
            RecordingStrategy(name: "a", snapshotUnits: [
                WorkUnitSnapshot(name: "x", state: .idle)
            ])
        ])
        let outer = CompositeStrategy(name: "outer", [inner])

        let snap = await outer.snapshot()
        #expect(snap.name == "outer")
        #expect(snap.children.count == 1)
        #expect(snap.children[0].name == "inner")
        #expect(snap.children[0].children.count == 1)
        #expect(snap.children[0].children[0].name == "a")
    }
}

// MARK: - Helpers

private final class OrderedStrategy: DaemonStrategy, @unchecked Sendable {
    let name: String
    private let order: LockIsolatedArray<String>

    init(name: String, order: LockIsolatedArray<String>) {
        self.name = name
        self.order = order
    }

    func start(context: DaemonContext) async throws {
        order.append("start:\(name)")
    }

    func stop() async {
        order.append("stop:\(name)")
    }

    func snapshot() async -> StrategySnapshot {
        StrategySnapshot(name: name, kind: "ordered", workUnits: [])
    }
}

private final class LockIsolatedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Element]

    init(_ initial: [Element] = []) { _values = initial }

    var values: [Element] { lock.withLock { _values } }
    func append(_ v: Element) { lock.withLock { _values.append(v) } }
}
