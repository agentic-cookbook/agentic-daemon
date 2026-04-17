import Foundation

/// A ``DaemonStrategy`` that composes other strategies.
///
/// Starts children in declaration order and stops them in reverse order.
/// Snapshots nest children under the composite.
///
///     let strategy = CompositeStrategy([
///         TimingStrategy(taskSource: taskSource),
///         EventStrategy(trigger: .directory(dropDir), handler: ingestionHandler)
///     ])
///
/// If a child's `start` throws, already-started siblings are stopped in
/// reverse order before the error propagates — the daemon sees either
/// "fully started" or "nothing started".
public final class CompositeStrategy: DaemonStrategy, @unchecked Sendable {
    public let name: String
    public let children: [any DaemonStrategy]

    public init(name: String = "composite", _ children: [any DaemonStrategy]) {
        self.name = name
        self.children = children
    }

    public func start(context: DaemonContext) async throws {
        var started: [any DaemonStrategy] = []
        do {
            for child in children {
                try await child.start(context: context)
                started.append(child)
            }
        } catch {
            for child in started.reversed() {
                await child.stop()
            }
            throw error
        }
    }

    public func stop() async {
        for child in children.reversed() {
            await child.stop()
        }
    }

    public func snapshot() async -> StrategySnapshot {
        var childSnapshots: [StrategySnapshot] = []
        for child in children {
            childSnapshots.append(await child.snapshot())
        }
        return StrategySnapshot(
            name: name,
            kind: Self.kind,
            workUnits: [],
            children: childSnapshots
        )
    }

    public static let kind = "composite"
}
