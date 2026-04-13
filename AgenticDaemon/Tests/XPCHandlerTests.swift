import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite("XPCHandler")
struct XPCHandlerTests {

    // MARK: - Helpers

    func makeHandler(
        getStatus: @escaping @Sendable () async -> DaemonStatus = { emptyStatus() },
        getCrashReports: @escaping @Sendable () -> [CrashReport] = { [] },
        enableJob: @escaping @Sendable (String) async -> Bool = { _ in true },
        disableJob: @escaping @Sendable (String) async -> Bool = { _ in true },
        triggerJob: @escaping @Sendable (String) async -> Bool = { _ in true },
        clearBlacklist: @escaping @Sendable (String) -> Bool = { _ in true },
        onShutdown: @escaping @Sendable () -> Void = {}
    ) -> XPCHandler {
        XPCHandler(dependencies: .init(
            getStatus: getStatus,
            getCrashReports: getCrashReports,
            enableJob: enableJob,
            disableJob: disableJob,
            triggerJob: triggerJob,
            clearBlacklist: clearBlacklist,
            onShutdown: onShutdown
        ))
    }

    // MARK: - getDaemonStatus

    @Test("getDaemonStatus encodes DaemonStatus to JSON")
    func getDaemonStatusEncodesJSON() async {
        let status = DaemonStatus(
            uptimeSeconds: 42,
            jobCount: 1,
            lastTick: Date(timeIntervalSince1970: 0),
            jobs: []
        )
        let handler = makeHandler(getStatus: { status })

        let data: Data = await withCheckedContinuation { cont in
            handler.getDaemonStatus { @Sendable data in cont.resume(returning: data) }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(DaemonStatus.self, from: data)
        #expect(decoded?.uptimeSeconds == 42)
        #expect(decoded?.jobCount == 1)
    }

    // MARK: - getCrashReports

    @Test("getCrashReports encodes reports to JSON")
    func getCrashReportsEncodesJSON() {
        let report = CrashReport(
            taskName: "sync",
            timestamp: Date(timeIntervalSince1970: 1_000),
            signal: "SIGSEGV",
            exceptionType: "EXC_BAD_ACCESS",
            faultingThread: 0,
            stackTrace: nil,
            source: .plcrash
        )
        let handler = makeHandler(getCrashReports: { [report] })

        let result = LockIsolated(Data())
        handler.getCrashReports { @Sendable data in result.setValue(data) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([CrashReport].self, from: result.value)
        #expect(decoded?.count == 1)
        #expect(decoded?.first?.taskName == "sync")
        #expect(decoded?.first?.exceptionType == "EXC_BAD_ACCESS")
    }

    // MARK: - triggerJob

    @Test("triggerJob calls triggerJob dependency and returns true on success")
    func triggerJobSuccess() async {
        let triggeredName = LockIsolated<String?>(nil)
        let handler = makeHandler(triggerJob: { @Sendable name in
            triggeredName.setValue(name)
            return true
        })

        let success: Bool = await withCheckedContinuation { cont in
            handler.triggerJob("my-job") { @Sendable s in cont.resume(returning: s) }
        }

        #expect(success == true)
        #expect(triggeredName.value == "my-job")
    }

    @Test("triggerJob returns false when dependency returns false")
    func triggerJobFailure() async {
        let handler = makeHandler(triggerJob: { @Sendable _ in false })

        let success: Bool = await withCheckedContinuation { cont in
            handler.triggerJob("ghost") { @Sendable s in cont.resume(returning: s) }
        }
        #expect(success == false)
    }

    // MARK: - enableJob / disableJob

    @Test("enableJob calls enableJob dependency")
    func enableJobCallsDependency() async {
        let enabledName = LockIsolated<String?>(nil)
        let handler = makeHandler(enableJob: { @Sendable name in
            enabledName.setValue(name)
            return true
        })

        let success: Bool = await withCheckedContinuation { cont in
            handler.enableJob("cleanup") { @Sendable s in cont.resume(returning: s) }
        }
        #expect(success == true)
        #expect(enabledName.value == "cleanup")
    }

    @Test("disableJob calls disableJob dependency")
    func disableJobCallsDependency() async {
        let disabledName = LockIsolated<String?>(nil)
        let handler = makeHandler(disableJob: { @Sendable name in
            disabledName.setValue(name)
            return true
        })

        let success: Bool = await withCheckedContinuation { cont in
            handler.disableJob("cleanup") { @Sendable s in cont.resume(returning: s) }
        }
        #expect(success == true)
        #expect(disabledName.value == "cleanup")
    }

    // MARK: - clearBlacklist

    @Test("clearBlacklist calls clearBlacklist dependency")
    func clearBlacklistCallsDependency() async {
        let clearedName = LockIsolated<String?>(nil)
        let handler = makeHandler(clearBlacklist: { @Sendable name in
            clearedName.setValue(name)
            return true
        })

        let success: Bool = await withCheckedContinuation { cont in
            handler.clearBlacklist("bad-job") { @Sendable s in cont.resume(returning: s) }
        }
        #expect(success == true)
        #expect(clearedName.value == "bad-job")
    }

    // MARK: - shutdown

    @Test("shutdown calls onShutdown dependency")
    func shutdownCallsDependency() async {
        let shutdownCalled = LockIsolated(false)
        let handler = makeHandler(onShutdown: { @Sendable in shutdownCalled.setValue(true) })

        await withCheckedContinuation { cont in
            handler.shutdown { @Sendable in cont.resume() }
        }
        #expect(shutdownCalled.value == true)
    }
}

// MARK: - Thread-safe value holder for tests

/// A simple lock-protected container for capturing mutable state in @Sendable closures.
final class LockIsolated<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()

    init(_ value: T) { _value = value }

    var value: T {
        lock.withLock { _value }
    }

    func setValue(_ newValue: T) {
        lock.withLock { _value = newValue }
    }
}

private func emptyStatus() -> DaemonStatus {
    DaemonStatus(uptimeSeconds: 0, jobCount: 0, lastTick: Date(timeIntervalSince1970: 0), jobs: [])
}
