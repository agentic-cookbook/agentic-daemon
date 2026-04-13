# Menu Bar Companion App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `LSUIElement` menu bar app that communicates with `agentic-daemon` via XPC to display job status, crash reports, and provide full daemon/job control.

**Architecture:** The daemon registers a Mach XPC service (`com.agentic-cookbook.daemon.xpc`). A companion app connects via `NSXPCConnection` and polls every 5 seconds for status. Shared Codable types (`DaemonStatus`, `JobConfig`, `CrashReport`) live in a new `AgenticXPCProtocol` library; only the `@objc` XPC protocol and those types cross the module boundary, so the companion binary never links PLCrashReporter.

**Tech Stack:** Swift 6, strict concurrency, `NSXPCConnection`/`NSXPCListener`, `NSStatusItem`, `NSApplication(.accessory)`, Swift Testing framework (matches existing tests).

---

## File Map

**New targets added to `AgenticDaemon/Package.swift`:**
- `AgenticXPCProtocol` — library, `Sources/AgenticXPCProtocol/`
- `AgenticMenuBarLib` — library, `Sources/AgenticMenuBarLib/`
- `AgenticMenuBar` — executable, `Sources/AgenticMenuBar/`
- `AgenticMenuBarTests` — test target, `Tests/AgenticMenuBarTests/`

**Files moved** from `AgenticDaemonLib` → `AgenticXPCProtocol`:
- `Sources/AgenticDaemonLib/StatusWriter.swift` → `Sources/AgenticXPCProtocol/DaemonStatus.swift` (only the `DaemonStatus` struct; `StatusWriter` stays)
- `Sources/AgenticDaemonLib/Models/JobConfig.swift` → `Sources/AgenticXPCProtocol/JobConfig.swift`
- `Sources/AgenticDaemonLib/CrashReport.swift` → `Sources/AgenticXPCProtocol/CrashReport.swift`

**Files created:**
- `Sources/AgenticXPCProtocol/AgenticDaemonXPC.swift` — `@objc` XPC protocol
- `Sources/AgenticDaemonLib/XPCHandler.swift` — implements `AgenticDaemonXPC` via closures
- `Sources/AgenticDaemonLib/XPCServer.swift` — `NSXPCListener` wrapper
- `Sources/AgenticMenuBarLib/DaemonClient.swift` — async XPC client
- `Sources/AgenticMenuBarLib/MenuBuilder.swift` — builds `NSMenu` from `DaemonStatus` + crashes
- `Sources/AgenticMenuBarLib/CrashDetailWindow.swift` — `NSWindow` for full crash report
- `Sources/AgenticMenuBarLib/AppDelegate.swift` — `NSStatusItem` owner, refresh timer
- `Sources/AgenticMenuBar/main.swift` — entry point
- `Tests/AgenticMenuBarTests/MenuBuilderTests.swift`
- `com.agentic-cookbook.menubar.plist` — companion LaunchAgent plist

**Files modified:**
- `AgenticDaemon/Package.swift` — new targets + dependency wiring
- `Sources/AgenticDaemonLib/Exports.swift` — add `@_exported import AgenticXPCProtocol`
- `Sources/AgenticDaemonLib/StatusWriter.swift` — remove `DaemonStatus` struct (moved)
- `Sources/AgenticDaemonLib/Models/JobDescriptor.swift` — `JobConfig` now from `AgenticXPCProtocol` (no source change needed once re-exported)
- `Sources/AgenticDaemonLib/Scheduler.swift` — add `triggerJob(name:)` method
- `Sources/AgenticDaemonLib/DaemonController.swift` — add `XPCServer`, `startDate`, `makeXPCHandler()`
- `com.agentic-cookbook.daemon.plist` — add `MachServices` key
- `install.sh` — build + install companion binary + companion plist
- `Tests/StatusWriterTests.swift` — update `JobStatus` construction for new fields

---

## Task 1: Add `AgenticXPCProtocol` target to Package.swift

**Files:**
- Modify: `AgenticDaemon/Package.swift`

- [ ] **Step 1: Add the new library target and update `AgenticDaemonLib` dependency**

Replace the `targets` array in `AgenticDaemon/Package.swift` with:

```swift
targets: [
    .target(
        name: "AgenticJobKit",
        path: "Sources/AgenticJobKit"
    ),
    .target(
        name: "AgenticXPCProtocol",
        path: "Sources/AgenticXPCProtocol"
    ),
    .target(
        name: "AgenticDaemonLib",
        dependencies: [
            "AgenticJobKit",
            "AgenticXPCProtocol",
            .product(name: "CrashReporter", package: "plcrashreporter")
        ],
        path: "Sources/AgenticDaemonLib"
    ),
    .executableTarget(
        name: "agentic-daemon",
        dependencies: ["AgenticDaemonLib"],
        path: "Sources/CLI"
    ),
    .testTarget(
        name: "AgenticDaemonTests",
        dependencies: ["AgenticDaemonLib"],
        path: "Tests",
        exclude: ["AgenticMenuBarTests"]
    )
]
```

- [ ] **Step 2: Create the source directory**

```bash
mkdir -p AgenticDaemon/Sources/AgenticXPCProtocol
```

- [ ] **Step 3: Verify the package resolves**

```bash
cd AgenticDaemon && swift package resolve
```

Expected: resolves without error (no sources yet, that's OK).

---

## Task 2: Move shared types to `AgenticXPCProtocol`

**Files:**
- Create: `AgenticDaemon/Sources/AgenticXPCProtocol/JobConfig.swift`
- Create: `AgenticDaemon/Sources/AgenticXPCProtocol/CrashReport.swift`
- Create: `AgenticDaemon/Sources/AgenticXPCProtocol/DaemonStatus.swift`
- Create: `AgenticDaemon/Sources/AgenticXPCProtocol/AgenticDaemonXPC.swift`
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/StatusWriter.swift`
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/Exports.swift`
- Delete: `AgenticDaemon/Sources/AgenticDaemonLib/Models/JobConfig.swift`
- Delete: `AgenticDaemon/Sources/AgenticDaemonLib/CrashReport.swift`

- [ ] **Step 1: Create `JobConfig.swift` in AgenticXPCProtocol**

Copy the full contents of `Sources/AgenticDaemonLib/Models/JobConfig.swift` to `Sources/AgenticXPCProtocol/JobConfig.swift` — identical file, no changes needed.

- [ ] **Step 2: Create `CrashReport.swift` in AgenticXPCProtocol**

Copy the full contents of `Sources/AgenticDaemonLib/CrashReport.swift` to `Sources/AgenticXPCProtocol/CrashReport.swift` — identical file, no changes needed.

- [ ] **Step 3: Create `DaemonStatus.swift` in AgenticXPCProtocol**

Extract just the `DaemonStatus` struct from `StatusWriter.swift` into a new file:

```swift
// Sources/AgenticXPCProtocol/DaemonStatus.swift
import Foundation

public struct DaemonStatus: Codable, Sendable {
    public let uptimeSeconds: TimeInterval
    public let jobCount: Int
    public let lastTick: Date
    public let jobs: [JobStatus]

    public struct JobStatus: Codable, Sendable {
        public let name: String
        public let nextRun: Date
        public let consecutiveFailures: Int
        public let isRunning: Bool
        public let config: JobConfig
        public let isBlacklisted: Bool

        public init(
            name: String,
            nextRun: Date,
            consecutiveFailures: Int,
            isRunning: Bool,
            config: JobConfig = .default,
            isBlacklisted: Bool = false
        ) {
            self.name = name
            self.nextRun = nextRun
            self.consecutiveFailures = consecutiveFailures
            self.isRunning = isRunning
            self.config = config
            self.isBlacklisted = isBlacklisted
        }
    }

    public init(uptimeSeconds: TimeInterval, jobCount: Int, lastTick: Date, jobs: [JobStatus]) {
        self.uptimeSeconds = uptimeSeconds
        self.jobCount = jobCount
        self.lastTick = lastTick
        self.jobs = jobs
    }
}
```

- [ ] **Step 4: Create `AgenticDaemonXPC.swift` in AgenticXPCProtocol**

```swift
// Sources/AgenticXPCProtocol/AgenticDaemonXPC.swift
import Foundation

/// XPC protocol between agentic-daemon and its menu bar companion.
/// Mach service name: com.agentic-cookbook.daemon.xpc
///
/// Complex types cross as JSON-encoded Data.
/// DaemonStatus  ← getDaemonStatus
/// [CrashReport] ← getCrashReports
@objc public protocol AgenticDaemonXPC {
    func getDaemonStatus(reply: @escaping (Data) -> Void)
    func getCrashReports(reply: @escaping (Data) -> Void)
    func enableJob(_ name: String, reply: @escaping (Bool) -> Void)
    func disableJob(_ name: String, reply: @escaping (Bool) -> Void)
    func triggerJob(_ name: String, reply: @escaping (Bool) -> Void)
    func clearBlacklist(_ name: String, reply: @escaping (Bool) -> Void)
    func shutdown(reply: @escaping () -> Void)
}
```

- [ ] **Step 5: Remove `DaemonStatus` from `StatusWriter.swift`**

Delete the `DaemonStatus` struct from `Sources/AgenticDaemonLib/StatusWriter.swift`, leaving only `StatusWriter`. The file should look like:

```swift
import Foundation
import os

public struct StatusWriter: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "StatusWriter"
    )
    private let statusURL: URL

    public init(statusURL: URL) {
        self.statusURL = statusURL
    }

    public func write(status: DaemonStatus) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(status)
            try data.write(to: statusURL, options: .atomic)
        } catch {
            logger.error("Failed to write status file: \(error)")
        }
    }
}
```

- [ ] **Step 6: Re-export `AgenticXPCProtocol` from `AgenticDaemonLib`**

Update `Sources/AgenticDaemonLib/Exports.swift`:

```swift
@_exported import AgenticJobKit
@_exported import AgenticXPCProtocol
```

This makes `DaemonStatus`, `JobConfig`, `CrashReport`, `AgenticDaemonXPC` automatically available to any code that imports `AgenticDaemonLib`, with no import changes needed in existing files.

- [ ] **Step 7: Delete the original source files**

```bash
rm AgenticDaemon/Sources/AgenticDaemonLib/Models/JobConfig.swift
rm AgenticDaemon/Sources/AgenticDaemonLib/CrashReport.swift
```

- [ ] **Step 8: Build to verify**

```bash
cd AgenticDaemon && swift build
```

Expected: builds cleanly. All existing code still finds `JobConfig`, `DaemonStatus`, `CrashReport` via the re-export.

- [ ] **Step 9: Run tests to verify nothing broke**

```bash
cd AgenticDaemon && swift test
```

Expected: all existing tests pass.

- [ ] **Step 10: Commit**

```bash
git add AgenticDaemon/Package.swift \
    AgenticDaemon/Sources/AgenticXPCProtocol/ \
    AgenticDaemon/Sources/AgenticDaemonLib/Exports.swift \
    AgenticDaemon/Sources/AgenticDaemonLib/StatusWriter.swift
git commit -m "feat: add AgenticXPCProtocol target, move shared types"
```

---

## Task 3: Extend `DaemonStatus.JobStatus` — tests

**Files:**
- Modify: `AgenticDaemon/Tests/StatusWriterTests.swift`

The `JobStatus` struct now has `config` and `isBlacklisted` fields (added in Task 2 with defaults). This task adds test coverage to prove round-trip encoding works.

- [ ] **Step 1: Add tests for new `JobStatus` fields**

Add to the `StatusWriterTests` suite in `Tests/StatusWriterTests.swift`:

```swift
@Test("JobStatus encodes and decodes config and isBlacklisted")
func jobStatusRoundTripsNewFields() throws {
    let tmpDir = makeTempDir(prefix: "status-fields")
    let statusURL = tmpDir.appending(path: "status.json")
    let writer = StatusWriter(statusURL: statusURL)

    let config = JobConfig(
        intervalSeconds: 120,
        enabled: true,
        timeout: 45,
        runAtWake: false,
        backoffOnFailure: false
    )
    let snapshot = DaemonStatus(
        uptimeSeconds: 30,
        jobCount: 1,
        lastTick: Date.now,
        jobs: [
            DaemonStatus.JobStatus(
                name: "worker",
                nextRun: Date.now.addingTimeInterval(60),
                consecutiveFailures: 1,
                isRunning: false,
                config: config,
                isBlacklisted: true
            )
        ]
    )

    writer.write(status: snapshot)

    let data = try Data(contentsOf: statusURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DaemonStatus.self, from: data)

    let job = try #require(decoded.jobs.first)
    #expect(job.config.intervalSeconds == 120)
    #expect(job.config.timeout == 45)
    #expect(job.config.runAtWake == false)
    #expect(job.config.backoffOnFailure == false)
    #expect(job.isBlacklisted == true)
    cleanupTempDir(tmpDir)
}

@Test("JobStatus uses default config and isBlacklisted=false when not specified")
func jobStatusDefaults() throws {
    let tmpDir = makeTempDir(prefix: "status-defaults")
    let statusURL = tmpDir.appending(path: "status.json")
    let writer = StatusWriter(statusURL: statusURL)

    let snapshot = DaemonStatus(
        uptimeSeconds: 10,
        jobCount: 1,
        lastTick: Date.now,
        jobs: [
            DaemonStatus.JobStatus(
                name: "job-a",
                nextRun: Date.now.addingTimeInterval(60),
                consecutiveFailures: 0,
                isRunning: false
                // config and isBlacklisted use defaults
            )
        ]
    )

    writer.write(status: snapshot)

    let data = try Data(contentsOf: statusURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DaemonStatus.self, from: data)

    let job = try #require(decoded.jobs.first)
    #expect(job.config.intervalSeconds == 60) // default
    #expect(job.isBlacklisted == false)        // default
    cleanupTempDir(tmpDir)
}
```

- [ ] **Step 2: Run tests to verify they pass (fields were added in Task 2)**

```bash
cd AgenticDaemon && swift test --filter StatusWriterTests
```

Expected: all `StatusWriterTests` pass including the two new ones.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Tests/StatusWriterTests.swift
git commit -m "test: add JobStatus config+isBlacklisted field coverage"
```

---

## Task 4: Add `Scheduler.triggerJob(name:)`

**Files:**
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/Scheduler.swift`
- Modify: `AgenticDaemon/Tests/SchedulerTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/SchedulerTests.swift` inside the `@Suite("Scheduler", .serialized)` block:

```swift
@Test("triggerJob sets nextRun to now for a known job")
func triggerJobSetsNextRunToNow() async {
    let tmpDir = makeTempDir(prefix: "sched-trigger")
    createJobDir(in: tmpDir, name: "job-trigger", swiftSource: validJobSource())
    // Use a long interval so the job won't auto-run during the test
    let config = JobConfig(intervalSeconds: 3600)
    let descriptor = makeDescriptor(in: tmpDir, name: "job-trigger", config: config)
    let scheduler = Scheduler(buildDir: findBuildDir())

    await scheduler.syncJobs(discovered: [descriptor])

    // Advance time slightly so nextRun (= Date.now at sync) is in the past
    try? await Task.sleep(for: .milliseconds(20))

    // Trigger
    await scheduler.triggerJob(name: "job-trigger")

    let job = await scheduler.job(named: "job-trigger")
    let nextRun = try #require(job?.nextRun)

    // nextRun must be at or before the moment triggerJob was called
    #expect(nextRun.timeIntervalSinceNow <= 0.1)

    cleanupTempDir(tmpDir)
}

@Test("triggerJob is a no-op for unknown job")
func triggerJobUnknownIsNoOp() async {
    let scheduler = Scheduler(buildDir: findBuildDir())
    // Should not crash or assert
    await scheduler.triggerJob(name: "does-not-exist")
    let empty = await scheduler.isEmpty
    #expect(empty)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd AgenticDaemon && swift test --filter "SchedulerTests/triggerJob"
```

Expected: compile error — `value of type 'Scheduler' has no member 'triggerJob'`.

- [ ] **Step 3: Add `triggerJob(name:)` to `Scheduler`**

Add this method to `Sources/AgenticDaemonLib/Scheduler.swift`, after the `job(named:)` method:

```swift
public func triggerJob(name: String) {
    guard scheduledJobs[name] != nil else { return }
    scheduledJobs[name]?.nextRun = Date.now
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd AgenticDaemon && swift test --filter SchedulerTests
```

Expected: all `SchedulerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/Scheduler.swift \
    AgenticDaemon/Tests/SchedulerTests.swift
git commit -m "feat: add Scheduler.triggerJob(name:)"
```

---

## Task 5: Create `XPCHandler` (TDD)

**Files:**
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/XPCHandler.swift`
- Create: `AgenticDaemon/Tests/XPCHandlerTests.swift`

`XPCHandler` implements `AgenticDaemonXPC` via injected closures, making it fully testable without a running XPC server.

- [ ] **Step 1: Write the failing tests**

Create `AgenticDaemon/Tests/XPCHandlerTests.swift`:

```swift
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

        let data = await withCheckedContinuation { cont in
            handler.getDaemonStatus { cont.resume(returning: $0) }
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
            jobName: "sync",
            timestamp: Date(timeIntervalSince1970: 1_000),
            signal: "SIGSEGV",
            exceptionType: "EXC_BAD_ACCESS",
            faultingThread: 0,
            stackTrace: nil,
            source: .plcrash
        )
        let handler = makeHandler(getCrashReports: { [report] })

        var result = Data()
        handler.getCrashReports { result = $0 }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([CrashReport].self, from: result)
        #expect(decoded?.count == 1)
        #expect(decoded?.first?.jobName == "sync")
        #expect(decoded?.first?.exceptionType == "EXC_BAD_ACCESS")
    }

    // MARK: - triggerJob

    @Test("triggerJob calls triggerJob dependency and returns true on success")
    func triggerJobSuccess() async {
        var triggeredName: String?
        let handler = makeHandler(triggerJob: { name in
            triggeredName = name
            return true
        })

        let success = await withCheckedContinuation { cont in
            handler.triggerJob("my-job") { cont.resume(returning: $0) }
        }

        #expect(success == true)
        #expect(triggeredName == "my-job")
    }

    @Test("triggerJob returns false when dependency returns false")
    func triggerJobFailure() async {
        let handler = makeHandler(triggerJob: { _ in false })

        let success = await withCheckedContinuation { cont in
            handler.triggerJob("ghost") { cont.resume(returning: $0) }
        }
        #expect(success == false)
    }

    // MARK: - enableJob / disableJob

    @Test("enableJob calls enableJob dependency")
    func enableJobCallsDependency() async {
        var enabledName: String?
        let handler = makeHandler(enableJob: { name in
            enabledName = name
            return true
        })

        let success = await withCheckedContinuation { cont in
            handler.enableJob("cleanup") { cont.resume(returning: $0) }
        }
        #expect(success == true)
        #expect(enabledName == "cleanup")
    }

    @Test("disableJob calls disableJob dependency")
    func disableJobCallsDependency() async {
        var disabledName: String?
        let handler = makeHandler(disableJob: { name in
            disabledName = name
            return true
        })

        let success = await withCheckedContinuation { cont in
            handler.disableJob("cleanup") { cont.resume(returning: $0) }
        }
        #expect(success == true)
        #expect(disabledName == "cleanup")
    }

    // MARK: - clearBlacklist

    @Test("clearBlacklist calls clearBlacklist dependency")
    func clearBlacklistCallsDependency() async {
        var clearedName: String?
        let handler = makeHandler(clearBlacklist: { name in
            clearedName = name
            return true
        })

        let success = await withCheckedContinuation { cont in
            handler.clearBlacklist("bad-job") { cont.resume(returning: $0) }
        }
        #expect(success == true)
        #expect(clearedName == "bad-job")
    }

    // MARK: - shutdown

    @Test("shutdown calls onShutdown dependency")
    func shutdownCallsDependency() async {
        var shutdownCalled = false
        let handler = makeHandler(onShutdown: { shutdownCalled = true })

        await withCheckedContinuation { cont in
            handler.shutdown { cont.resume() }
        }
        #expect(shutdownCalled == true)
    }
}

private func emptyStatus() -> DaemonStatus {
    DaemonStatus(uptimeSeconds: 0, jobCount: 0, lastTick: Date(timeIntervalSince1970: 0), jobs: [])
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd AgenticDaemon && swift test --filter XPCHandlerTests
```

Expected: compile error — `cannot find type 'XPCHandler' in scope`.

- [ ] **Step 3: Create `XPCHandler.swift`**

Create `AgenticDaemon/Sources/AgenticDaemonLib/XPCHandler.swift`:

```swift
import Foundation
import os

/// Implements AgenticDaemonXPC by delegating each operation to an injected closure.
/// This design keeps XPCHandler testable without a running XPC server or real Scheduler.
final class XPCHandler: NSObject, AgenticDaemonXPC, @unchecked Sendable {

    struct Dependencies: Sendable {
        /// Returns the current daemon status, encoded by the caller.
        let getStatus: @Sendable () async -> DaemonStatus
        /// Returns all stored crash reports.
        let getCrashReports: @Sendable () -> [CrashReport]
        /// Enables the named job. Returns false if the job is not found.
        let enableJob: @Sendable (String) async -> Bool
        /// Disables the named job. Returns false if the job is not found.
        let disableJob: @Sendable (String) async -> Bool
        /// Sets the named job's next run time to now. Returns false if not found.
        let triggerJob: @Sendable (String) async -> Bool
        /// Clears the crash blacklist for the named job. Always returns true.
        let clearBlacklist: @Sendable (String) -> Bool
        /// Shuts the daemon down.
        let onShutdown: @Sendable () -> Void
    }

    private let deps: Dependencies
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    func getDaemonStatus(reply: @escaping (Data) -> Void) {
        Task {
            let status = await deps.getStatus()
            reply((try? encoder.encode(status)) ?? Data())
        }
    }

    func getCrashReports(reply: @escaping (Data) -> Void) {
        let reports = deps.getCrashReports()
        reply((try? encoder.encode(reports)) ?? Data())
    }

    func enableJob(_ name: String, reply: @escaping (Bool) -> Void) {
        Task { reply(await deps.enableJob(name)) }
    }

    func disableJob(_ name: String, reply: @escaping (Bool) -> Void) {
        Task { reply(await deps.disableJob(name)) }
    }

    func triggerJob(_ name: String, reply: @escaping (Bool) -> Void) {
        Task { reply(await deps.triggerJob(name)) }
    }

    func clearBlacklist(_ name: String, reply: @escaping (Bool) -> Void) {
        reply(deps.clearBlacklist(name))
    }

    func shutdown(reply: @escaping () -> Void) {
        deps.onShutdown()
        reply()
    }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd AgenticDaemon && swift test --filter XPCHandlerTests
```

Expected: all 8 `XPCHandlerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/XPCHandler.swift \
    AgenticDaemon/Tests/XPCHandlerTests.swift
git commit -m "feat: add XPCHandler with closure-based dependencies"
```

---

## Task 6: Create `XPCServer`

**Files:**
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/XPCServer.swift`

No unit tests — `NSXPCListener(machServiceName:)` requires a running Mach service registered by launchd. This is covered by the end-to-end path in Task 8.

- [ ] **Step 1: Create `XPCServer.swift`**

```swift
// Sources/AgenticDaemonLib/XPCServer.swift
import Foundation
import os

final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "XPCServer"
    )
    private let listener: NSXPCListener
    private let handler: XPCHandler

    init(handler: XPCHandler) {
        self.listener = NSXPCListener(machServiceName: "com.agentic-cookbook.daemon.xpc")
        self.handler = handler
    }

    func start() {
        listener.delegate = self
        listener.resume()
        logger.info("XPC server listening on com.agentic-cookbook.daemon.xpc")
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AgenticDaemonXPC.self)
        connection.exportedObject = handler
        connection.resume()
        logger.info("XPC client connected")
        return true
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd AgenticDaemon && swift build
```

Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/XPCServer.swift
git commit -m "feat: add XPCServer wrapping NSXPCListener"
```

---

## Task 7: Wire `XPCServer` into `DaemonController`

**Files:**
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift`

- [ ] **Step 1: Add `startDate`, `xpcServer`, and `makeXPCHandler()` to `DaemonController`**

Replace the entire `DaemonController.swift` with:

```swift
import Foundation
import os

public final class DaemonController: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "DaemonController"
    )

    private let supportDirectory: URL
    private let jobsDirectory: URL
    public let scheduler: Scheduler
    private let discovery: JobDiscovery
    private let crashTracker: CrashTracker
    private let crashReportCollector: CrashReportCollector
    private let crashReportStore: CrashReportStore
    private let analytics: any AnalyticsProvider
    private var watcher: DirectoryWatcher?
    private var running = true
    private let startDate = Date.now

    public init(analytics: any AnalyticsProvider = LogAnalyticsProvider()) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        supportDirectory = appSupport.appending(path: "com.agentic-cookbook.daemon")
        jobsDirectory = supportDirectory.appending(path: "jobs")
        discovery = JobDiscovery(jobsDirectory: jobsDirectory)
        let libDir = supportDirectory.appending(path: "lib")
        crashTracker = CrashTracker(stateDir: supportDirectory)
        crashReportCollector = CrashReportCollector(supportDirectory: supportDirectory)
        crashReportStore = CrashReportStore(crashesDirectory: supportDirectory.appending(path: "crashes"))
        self.analytics = analytics
        scheduler = Scheduler(buildDir: libDir, crashTracker: crashTracker, analytics: analytics)
    }

    public func run() async {
        logger.info("Starting agentic-daemon")

        createDirectories()

        do {
            try crashReportCollector.installCrashHandler()
        } catch {
            logger.error("Failed to install crash handler: \(error)")
        }

        if let crashedJob = crashTracker.crashedJobName() {
            let reports = crashReportCollector.collectPendingReports(crashedJobName: crashedJob)
            for report in reports {
                analytics.track(.jobCrashed(
                    name: report.jobName,
                    signal: report.signal,
                    exceptionType: report.exceptionType
                ))
                do {
                    try crashReportStore.save(report)
                } catch {
                    logger.error("Failed to save crash report: \(error)")
                }
            }
            if reports.isEmpty {
                logger.info("Crash detected for \(crashedJob) but no crash reports found")
            }
        }

        crashReportStore.cleanup(retentionDays: 30)
        await scheduler.recoverFromCrash()

        let jobs = discovery.discover()
        await scheduler.syncJobs(discovered: jobs)

        watcher = DirectoryWatcher(directory: jobsDirectory) { [self] in
            Task {
                let updated = self.discovery.discover()
                await self.scheduler.syncJobs(discovered: updated)
            }
        }
        watcher?.start()

        // Start XPC server so the menu bar companion can connect
        let xpcServer = XPCServer(handler: makeXPCHandler())
        xpcServer.start()

        logger.info("Daemon running, \(jobs.count) job(s) loaded")

        while running {
            await scheduler.tick()
            try? await Task.sleep(for: .seconds(1))
        }

        watcher?.stop()
        logger.info("Daemon stopped")
    }

    public func shutdown() {
        logger.info("Shutdown requested")
        running = false
    }

    // MARK: - XPC

    private func makeXPCHandler() -> XPCHandler {
        let captured = (
            scheduler: scheduler,
            discovery: discovery,
            crashTracker: crashTracker,
            crashReportStore: crashReportStore,
            jobsDirectory: jobsDirectory,
            startDate: startDate
        )

        return XPCHandler(dependencies: .init(
            getStatus: {
                let names = await captured.scheduler.jobNames
                var jobs: [DaemonStatus.JobStatus] = []
                for name in names.sorted() {
                    guard let sj = await captured.scheduler.job(named: name) else { continue }
                    jobs.append(DaemonStatus.JobStatus(
                        name: sj.descriptor.name,
                        nextRun: sj.nextRun,
                        consecutiveFailures: sj.consecutiveFailures,
                        isRunning: sj.isRunning,
                        config: sj.descriptor.config,
                        isBlacklisted: captured.crashTracker.isBlacklisted(jobName: name)
                    ))
                }
                return DaemonStatus(
                    uptimeSeconds: Date.now.timeIntervalSince(captured.startDate),
                    jobCount: jobs.count,
                    lastTick: Date.now,
                    jobs: jobs
                )
            },
            getCrashReports: {
                captured.crashReportStore.loadAll()
                    .sorted { $0.timestamp > $1.timestamp }
            },
            enableJob: { name in
                let configURL = captured.jobsDirectory
                    .appending(path: name)
                    .appending(path: "config.json")
                return Self.updateJobEnabled(true, at: configURL, discovery: captured.discovery, scheduler: captured.scheduler)
            },
            disableJob: { name in
                let configURL = captured.jobsDirectory
                    .appending(path: name)
                    .appending(path: "config.json")
                return Self.updateJobEnabled(false, at: configURL, discovery: captured.discovery, scheduler: captured.scheduler)
            },
            triggerJob: { name in
                let exists = await captured.scheduler.jobNames.contains(name)
                guard exists else { return false }
                await captured.scheduler.triggerJob(name: name)
                return true
            },
            clearBlacklist: { name in
                captured.crashTracker.clearBlacklist(jobName: name)
                return true
            },
            onShutdown: { [weak self] in self?.shutdown() }
        ))
    }

    /// Writes an updated `enabled` flag to `config.json`, then re-syncs the scheduler.
    /// Uses a static method to avoid capturing `self` in a Sendable closure.
    private static func updateJobEnabled(
        _ enabled: Bool,
        at configURL: URL,
        discovery: JobDiscovery,
        scheduler: Scheduler
    ) async -> Bool {
        // Read existing config (fall back to default if missing/corrupt)
        let existing: JobConfig
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder().decode(JobConfig.self, from: data) {
            existing = decoded
        } else {
            // config.json doesn't exist — job uses defaults. Create it.
            existing = .default
        }

        let updated = JobConfig(
            intervalSeconds: existing.intervalSeconds,
            enabled: enabled,
            timeout: existing.timeout,
            runAtWake: existing.runAtWake,
            backoffOnFailure: existing.backoffOnFailure
        )

        guard let data = try? JSONEncoder().encode(updated) else { return false }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            return false
        }

        // Re-discover and sync so the Scheduler picks up the change
        let jobs = discovery.discover()
        await scheduler.syncJobs(discovered: jobs)
        return true
    }

    // MARK: - Private

    private func createDirectories() {
        let fm = FileManager.default
        for dir in [jobsDirectory, supportDirectory.appending(path: "lib"), supportDirectory.appending(path: "crashes")] {
            let path = dir.path(percentEncoded: false)
            if !fm.fileExists(atPath: path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    logger.info("Created directory: \(path)")
                } catch {
                    logger.error("Failed to create directory: \(error)")
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and test**

```bash
cd AgenticDaemon && swift build && swift test
```

Expected: all tests pass.

- [ ] **Step 3: Update the daemon's launchd plist to register the Mach service**

`NSXPCListener(machServiceName:)` requires the service name to be declared in the LaunchAgent plist. Add the `MachServices` key to `com.agentic-cookbook.daemon.plist`:

```xml
<key>MachServices</key>
<dict>
    <key>com.agentic-cookbook.daemon.xpc</key>
    <true/>
</dict>
```

Full updated plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agentic-cookbook.daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>${HOME}/Library/Application Support/com.agentic-cookbook.daemon/agentic-daemon</string>
    </array>

    <key>MachServices</key>
    <dict>
        <key>com.agentic-cookbook.daemon.xpc</key>
        <true/>
    </dict>

    <key>KeepAlive</key>
    <true/>

    <key>RunAtLoad</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>WorkingDirectory</key>
    <string>${HOME}/Library/Application Support/com.agentic-cookbook.daemon</string>

    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/com.agentic-cookbook.daemon/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/com.agentic-cookbook.daemon/stderr.log</string>
</dict>
</plist>
```

- [ ] **Step 4: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift \
    com.agentic-cookbook.daemon.plist
git commit -m "feat: wire XPCServer into DaemonController, add MachServices to plist"
```

---

## Task 8: Add companion targets to Package.swift

**Files:**
- Modify: `AgenticDaemon/Package.swift`

- [ ] **Step 1: Add `AgenticMenuBarLib`, `AgenticMenuBar`, and `AgenticMenuBarTests` targets**

Replace the `targets` array in `AgenticDaemon/Package.swift`:

```swift
targets: [
    .target(
        name: "AgenticJobKit",
        path: "Sources/AgenticJobKit"
    ),
    .target(
        name: "AgenticXPCProtocol",
        path: "Sources/AgenticXPCProtocol"
    ),
    .target(
        name: "AgenticDaemonLib",
        dependencies: [
            "AgenticJobKit",
            "AgenticXPCProtocol",
            .product(name: "CrashReporter", package: "plcrashreporter")
        ],
        path: "Sources/AgenticDaemonLib"
    ),
    .executableTarget(
        name: "agentic-daemon",
        dependencies: ["AgenticDaemonLib"],
        path: "Sources/CLI"
    ),
    .target(
        name: "AgenticMenuBarLib",
        dependencies: ["AgenticXPCProtocol"],
        path: "Sources/AgenticMenuBarLib"
    ),
    .executableTarget(
        name: "AgenticMenuBar",
        dependencies: ["AgenticMenuBarLib"],
        path: "Sources/AgenticMenuBar"
    ),
    .testTarget(
        name: "AgenticDaemonTests",
        dependencies: ["AgenticDaemonLib"],
        path: "Tests",
        exclude: ["AgenticMenuBarTests"]
    ),
    .testTarget(
        name: "AgenticMenuBarTests",
        dependencies: ["AgenticMenuBarLib"],
        path: "Tests/AgenticMenuBarTests"
    )
]
```

- [ ] **Step 2: Create source directories**

```bash
mkdir -p AgenticDaemon/Sources/AgenticMenuBarLib
mkdir -p AgenticDaemon/Sources/AgenticMenuBar
mkdir -p AgenticDaemon/Tests/AgenticMenuBarTests
```

- [ ] **Step 3: Verify package resolves**

```bash
cd AgenticDaemon && swift package resolve
```

Expected: resolves without error.

- [ ] **Step 4: Commit**

```bash
git add AgenticDaemon/Package.swift
git commit -m "feat: add AgenticMenuBarLib, AgenticMenuBar, AgenticMenuBarTests targets"
```

---

## Task 9: Create `MenuBuilder` (TDD)

**Files:**
- Create: `AgenticDaemon/Sources/AgenticMenuBarLib/MenuBuilder.swift`
- Create: `AgenticDaemon/Tests/AgenticMenuBarTests/MenuBuilderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `AgenticDaemon/Tests/AgenticMenuBarTests/MenuBuilderTests.swift`:

```swift
import Testing
import AppKit
import Foundation
@testable import AgenticMenuBarLib

@Suite("MenuBuilder")
struct MenuBuilderTests {

    let noopHandlers = MenuBuilder.Handlers(
        onTriggerJob: { _ in },
        onEnableJob: { _ in },
        onDisableJob: { _ in },
        onClearBlacklist: { _ in },
        onShowCrash: { _ in },
        onStartDaemon: {},
        onStopDaemon: {},
        onRestartDaemon: {},
        onQuit: {}
    )

    @Test("nil status shows stopped state with Start Daemon item")
    func nilStatusShowsStoppedState() {
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: nil, crashes: [])
        let titles = menu.items.map(\.title)
        #expect(titles.contains { $0.localizedCaseInsensitiveContains("not running") })
        #expect(titles.contains("Start Daemon"))
        #expect(!titles.contains("Stop Daemon"))
    }

    @Test("running status shows job rows")
    func runningStatusShowsJobs() {
        let status = makeStatus(jobs: [
            makeJobStatus(name: "cleanup"),
            makeJobStatus(name: "sync", isRunning: true)
        ])
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: status, crashes: [])
        let allTitles = collectAllTitles(menu)
        #expect(allTitles.contains { $0.contains("cleanup") })
        #expect(allTitles.contains { $0.contains("sync") })
    }

    @Test("crashes section appears only when crashes exist")
    func crashesSectionVisibility() {
        let status = makeStatus(jobs: [])
        let builder = MenuBuilder(handlers: noopHandlers)

        let menuWithout = builder.build(status: status, crashes: [])
        #expect(!menuWithout.items.map(\.title).contains { $0.contains("CRASH") })

        let crash = CrashReport(
            jobName: "sync",
            timestamp: Date.now.addingTimeInterval(-3600),
            signal: nil,
            exceptionType: "EXC_BAD_ACCESS",
            faultingThread: nil,
            stackTrace: nil,
            source: .plcrash
        )
        let menuWith = builder.build(status: status, crashes: [crash])
        let titles = menuWith.items.map(\.title)
        #expect(titles.contains { $0.contains("CRASH") })
        #expect(collectAllTitles(menuWith).contains { $0.contains("sync") })
    }

    @Test("Quit item is always present")
    func quitAlwaysPresent() {
        let builder = MenuBuilder(handlers: noopHandlers)
        #expect(builder.build(status: nil, crashes: []).items.map(\.title).contains("Quit"))
        #expect(builder.build(status: makeStatus(jobs: []), crashes: []).items.map(\.title).contains("Quit"))
    }

    @Test("running status shows Stop Daemon, not Start Daemon")
    func runningDaemonShowsStopNotStart() {
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: makeStatus(jobs: []), crashes: [])
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Stop Daemon"))
        #expect(!titles.contains("Start Daemon"))
    }

    @Test("job submenu contains config and control items")
    func jobSubmenuContents() {
        let config = JobConfig(intervalSeconds: 120, enabled: true, timeout: 45, runAtWake: false, backoffOnFailure: false)
        let status = makeStatus(jobs: [makeJobStatus(name: "worker", config: config, isBlacklisted: true)])
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: status, crashes: [])

        // Find the job item with a submenu
        let jobItem = menu.items.first { $0.submenu != nil && $0.title.contains("worker") }
        let submenuTitles = jobItem?.submenu?.items.map(\.title) ?? []

        #expect(submenuTitles.contains { $0.contains("120") })   // interval
        #expect(submenuTitles.contains { $0.contains("45") })    // timeout
        #expect(submenuTitles.contains("Trigger Now"))
        #expect(submenuTitles.contains("Enable Job"))            // disabled → enable
        #expect(submenuTitles.contains("Clear Blacklist"))
    }
}

// MARK: - Helpers

private func makeStatus(jobs: [DaemonStatus.JobStatus]) -> DaemonStatus {
    DaemonStatus(uptimeSeconds: 60, jobCount: jobs.count, lastTick: Date.now, jobs: jobs)
}

private func makeJobStatus(
    name: String,
    config: JobConfig = .default,
    isRunning: Bool = false,
    isBlacklisted: Bool = false
) -> DaemonStatus.JobStatus {
    DaemonStatus.JobStatus(
        name: name,
        nextRun: Date.now.addingTimeInterval(60),
        consecutiveFailures: 0,
        isRunning: isRunning,
        config: config,
        isBlacklisted: isBlacklisted
    )
}

/// Collect titles from the menu and all submenus.
private func collectAllTitles(_ menu: NSMenu) -> [String] {
    menu.items.flatMap { item -> [String] in
        var titles = [item.title]
        if let sub = item.submenu {
            titles += collectAllTitles(sub)
        }
        return titles
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd AgenticDaemon && swift test --filter MenuBuilderTests
```

Expected: compile error — `cannot find type 'MenuBuilder' in scope`.

- [ ] **Step 3: Create `MenuBuilder.swift`**

Create `AgenticDaemon/Sources/AgenticMenuBarLib/MenuBuilder.swift`:

```swift
import AppKit
import Foundation

/// Builds an NSMenu from the latest DaemonStatus and crash list.
/// Stateless — build(status:crashes:) can be called on every refresh.
public final class MenuBuilder: @unchecked Sendable {

    public struct Handlers: Sendable {
        public let onTriggerJob: @Sendable (String) -> Void
        public let onEnableJob: @Sendable (String) -> Void
        public let onDisableJob: @Sendable (String) -> Void
        public let onClearBlacklist: @Sendable (String) -> Void
        public let onShowCrash: @Sendable (CrashReport) -> Void
        public let onStartDaemon: @Sendable () -> Void
        public let onStopDaemon: @Sendable () -> Void
        public let onRestartDaemon: @Sendable () -> Void
        public let onQuit: @Sendable () -> Void

        public init(
            onTriggerJob: @escaping @Sendable (String) -> Void,
            onEnableJob: @escaping @Sendable (String) -> Void,
            onDisableJob: @escaping @Sendable (String) -> Void,
            onClearBlacklist: @escaping @Sendable (String) -> Void,
            onShowCrash: @escaping @Sendable (CrashReport) -> Void,
            onStartDaemon: @escaping @Sendable () -> Void,
            onStopDaemon: @escaping @Sendable () -> Void,
            onRestartDaemon: @escaping @Sendable () -> Void,
            onQuit: @escaping @Sendable () -> Void
        ) {
            self.onTriggerJob = onTriggerJob
            self.onEnableJob = onEnableJob
            self.onDisableJob = onDisableJob
            self.onClearBlacklist = onClearBlacklist
            self.onShowCrash = onShowCrash
            self.onStartDaemon = onStartDaemon
            self.onStopDaemon = onStopDaemon
            self.onRestartDaemon = onRestartDaemon
            self.onQuit = onQuit
        }
    }

    private let handlers: Handlers

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    public func build(status: DaemonStatus?, crashes: [CrashReport]) -> NSMenu {
        let menu = NSMenu()

        if let status {
            addHeader(menu, status: status)
            menu.addItem(.separator())
            addJobsSection(menu, jobs: status.jobs)
            menu.addItem(.separator())
            if !crashes.isEmpty {
                addCrashesSection(menu, crashes: crashes)
                menu.addItem(.separator())
            }
            addDaemonControls(menu, running: true)
        } else {
            addStoppedHeader(menu)
            menu.addItem(.separator())
            menu.addItem(menuItem("Start Daemon", action: handlers.onStartDaemon))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", action: handlers.onQuit))
        return menu
    }

    // MARK: - Sections

    private func addHeader(_ menu: NSMenu, status: DaemonStatus) {
        let title = "agentic-daemon  ·  uptime \(formatUptime(status.uptimeSeconds))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addStoppedHeader(_ menu: NSMenu) {
        let item = NSMenuItem(title: "● Daemon not running", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addJobsSection(_ menu: NSMenu, jobs: [DaemonStatus.JobStatus]) {
        let header = NSMenuItem(title: "JOBS (\(jobs.count))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for job in jobs.sorted(by: { $0.name < $1.name }) {
            menu.addItem(makeJobItem(job))
        }
    }

    private func addCrashesSection(_ menu: NSMenu, crashes: [CrashReport]) {
        let header = NSMenuItem(title: "RECENT CRASHES (\(crashes.count))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for crash in crashes.prefix(5) {
            menu.addItem(makeCrashItem(crash))
        }
    }

    private func addDaemonControls(_ menu: NSMenu, running: Bool) {
        menu.addItem(menuItem("Restart Daemon", action: handlers.onRestartDaemon))
        menu.addItem(menuItem("Stop Daemon", action: handlers.onStopDaemon))
    }

    // MARK: - Job Items

    private func makeJobItem(_ job: DaemonStatus.JobStatus) -> NSMenuItem {
        let dot = job.isRunning ? "●" : (job.config.enabled ? "●" : "○")
        let nextRunText: String
        if job.isRunning {
            nextRunText = "running…"
        } else if !job.config.enabled {
            nextRunText = "disabled"
        } else {
            let secs = Int(max(0, job.nextRun.timeIntervalSinceNow))
            nextRunText = secs < 60 ? "next: \(secs)s" : "next: \(secs / 60)m"
        }

        let item = NSMenuItem(title: "\(dot) \(job.name)   \(nextRunText)", action: nil, keyEquivalent: "")
        item.submenu = makeJobSubmenu(job)
        return item
    }

    private func makeJobSubmenu(_ job: DaemonStatus.JobStatus) -> NSMenu {
        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem(title: job.name, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let subtitle: String
        if job.isRunning {
            subtitle = "Currently running"
        } else if !job.config.enabled {
            subtitle = "Disabled"
        } else {
            let secs = Int(max(0, job.nextRun.timeIntervalSinceNow))
            subtitle = "Next run in \(secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s")"
        }
        let subtitleItem = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
        subtitleItem.isEnabled = false
        menu.addItem(subtitleItem)
        menu.addItem(.separator())

        // Config
        addLabel(menu, "CONFIG")
        addInfo(menu, label: "Interval", value: "\(Int(job.config.intervalSeconds))s")
        addInfo(menu, label: "Timeout", value: "\(Int(job.config.timeout))s")
        addInfo(menu, label: "Run at wake", value: job.config.runAtWake ? "Yes" : "No")
        addInfo(menu, label: "Backoff", value: job.config.backoffOnFailure ? "Yes" : "No")
        menu.addItem(.separator())

        // Runtime
        addLabel(menu, "RUNTIME")
        addInfo(menu, label: "Failures", value: "\(job.consecutiveFailures)")
        addInfo(menu, label: "Blacklisted", value: job.isBlacklisted ? "Yes" : "No")
        menu.addItem(.separator())

        // Actions
        menu.addItem(menuItem("Trigger Now", action: { [handlers] in handlers.onTriggerJob(job.name) }))
        if job.config.enabled {
            menu.addItem(menuItem("Disable Job", action: { [handlers] in handlers.onDisableJob(job.name) }))
        } else {
            menu.addItem(menuItem("Enable Job", action: { [handlers] in handlers.onEnableJob(job.name) }))
        }
        if job.isBlacklisted {
            menu.addItem(menuItem("Clear Blacklist", action: { [handlers] in handlers.onClearBlacklist(job.name) }))
        }

        return menu
    }

    // MARK: - Crash Items

    private func makeCrashItem(_ crash: CrashReport) -> NSMenuItem {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let ago = formatter.localizedString(for: crash.timestamp, relativeTo: Date.now)
        let exc = crash.exceptionType ?? crash.signal ?? "unknown"
        let title = "⚠ \(crash.jobName) — \(ago)   \(exc)"
        return menuItem(title, action: { [handlers] in handlers.onShowCrash(crash) })
    }

    // MARK: - Helpers

    private func addLabel(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addInfo(_ menu: NSMenu, label: String, value: String) {
        let item = NSMenuItem(title: "\(label):  \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        menu.addItem(item)
    }

    private func menuItem(_ title: String, action: @escaping @Sendable () -> Void) -> NSMenuItem {
        let item = BlockMenuItem(title: title, action: action)
        return item
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// NSMenuItem subclass that holds an action closure.
/// Required because NSMenuItem target/action needs an @objc method on an NSObject.
private final class BlockMenuItem: NSMenuItem {
    private let block: @Sendable () -> Void

    init(title: String, action block: @escaping @Sendable () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("not implemented") }

    @objc private func invoke() { block() }
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd AgenticDaemon && swift test --filter MenuBuilderTests
```

Expected: all 6 `MenuBuilderTests` pass.

- [ ] **Step 5: Commit**

```bash
git add AgenticDaemon/Sources/AgenticMenuBarLib/MenuBuilder.swift \
    AgenticDaemon/Tests/AgenticMenuBarTests/MenuBuilderTests.swift
git commit -m "feat: add MenuBuilder with full job/crash menu construction"
```

---

## Task 10: Create `DaemonClient`

**Files:**
- Create: `AgenticDaemon/Sources/AgenticMenuBarLib/DaemonClient.swift`

`DaemonClient` wraps `NSXPCConnection` and bridges XPC callbacks to Swift `async`. Tested by integration (connect to a live daemon); unit tests for decoding logic only.

- [ ] **Step 1: Create `DaemonClient.swift`**

```swift
// Sources/AgenticMenuBarLib/DaemonClient.swift
import Foundation
import os

public enum DaemonClientError: Error, Sendable {
    case notConnected
    case proxyUnavailable
    case decodingFailed
    case operationFailed
}

/// Async wrapper around NSXPCConnection to com.agentic-cookbook.daemon.xpc.
/// Must be used from the @MainActor.
@MainActor
public final class DaemonClient {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "DaemonClient"
    )
    private var connection: NSXPCConnection?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init() {}

    public var isConnected: Bool { connection != nil }

    /// Opens the XPC connection. Safe to call multiple times.
    public func connect() {
        guard connection == nil else { return }
        let conn = NSXPCConnection(machServiceName: "com.agentic-cookbook.daemon.xpc")
        conn.remoteObjectInterface = NSXPCInterface(with: AgenticDaemonXPC.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect(reason: "invalidated") }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect(reason: "interrupted") }
        }
        conn.resume()
        connection = conn
        logger.info("XPC connection opened")
    }

    /// Closes the XPC connection.
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Status

    public func getDaemonStatus() async throws -> DaemonStatus {
        let proxy = try makeProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.getDaemonStatus { [decoder] data in
                if let status = try? decoder.decode(DaemonStatus.self, from: data) {
                    cont.resume(returning: status)
                } else {
                    cont.resume(throwing: DaemonClientError.decodingFailed)
                }
            }
        }
    }

    public func getCrashReports() async throws -> [CrashReport] {
        let proxy = try makeProxy()
        return try await withCheckedThrowingContinuation { cont in
            proxy.getCrashReports { [decoder] data in
                let reports = (try? decoder.decode([CrashReport].self, from: data)) ?? []
                cont.resume(returning: reports)
            }
        }
    }

    // MARK: - Job Control

    public func enableJob(_ name: String) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { cont in
            proxy.enableJob(name) { success in
                cont.resume(with: success ? .success(()) : .failure(DaemonClientError.operationFailed))
            }
        }
    }

    public func disableJob(_ name: String) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { cont in
            proxy.disableJob(name) { success in
                cont.resume(with: success ? .success(()) : .failure(DaemonClientError.operationFailed))
            }
        }
    }

    public func triggerJob(_ name: String) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { cont in
            proxy.triggerJob(name) { success in
                cont.resume(with: success ? .success(()) : .failure(DaemonClientError.operationFailed))
            }
        }
    }

    public func clearBlacklist(_ name: String) async throws {
        let proxy = try makeProxy()
        try await withCheckedThrowingContinuation { cont in
            proxy.clearBlacklist(name) { success in
                cont.resume(with: success ? .success(()) : .failure(DaemonClientError.operationFailed))
            }
        }
    }

    // MARK: - Daemon Control

    public func shutdown() async throws {
        let proxy = try makeProxy()
        await withCheckedContinuation { cont in
            proxy.shutdown { cont.resume() }
        }
        disconnect()
    }

    // MARK: - Private

    private func makeProxy() throws -> any AgenticDaemonXPC {
        guard let conn = connection else { throw DaemonClientError.notConnected }
        guard let proxy = conn.remoteObjectProxy(withErrorHandler: { [weak self] error in
            Task { @MainActor in
                self?.logger.error("XPC remote error: \(error)")
                self?.handleDisconnect(reason: "remote error")
            }
        }) as? any AgenticDaemonXPC else {
            throw DaemonClientError.proxyUnavailable
        }
        return proxy
    }

    private func handleDisconnect(reason: String) {
        connection = nil
        logger.info("XPC connection \(reason)")
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd AgenticDaemon && swift build --target AgenticMenuBarLib
```

Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Sources/AgenticMenuBarLib/DaemonClient.swift
git commit -m "feat: add DaemonClient async XPC wrapper"
```

---

## Task 11: Create `CrashDetailWindow`

**Files:**
- Create: `AgenticDaemon/Sources/AgenticMenuBarLib/CrashDetailWindow.swift`

- [ ] **Step 1: Create `CrashDetailWindow.swift`**

```swift
// Sources/AgenticMenuBarLib/CrashDetailWindow.swift
import AppKit
import Foundation

/// Opens a non-modal window showing the full content of a crash report.
/// Retains itself until the window is closed.
public final class CrashDetailWindow: NSObject, NSWindowDelegate, @unchecked Sendable {

    private let window: NSWindow

    public static func show(report: CrashReport) {
        // CrashDetailWindow retains itself via the window delegate until closed
        let viewer = CrashDetailWindow(report: report)
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(report: CrashReport) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Crash Report — \(report.jobName)"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = NSTextView(frame: scrollView.contentSize.asRect)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = Self.format(report)

        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
    }

    public func windowWillClose(_ notification: Notification) {
        // Break the retain cycle so this object is deallocated
        window.delegate = nil
    }

    // MARK: - Formatting

    private static func format(_ report: CrashReport) -> String {
        var lines: [String] = []
        lines.append("Job:             \(report.jobName)")
        lines.append("Timestamp:       \(report.timestamp)")
        lines.append("Source:          \(report.source.rawValue)")
        if let sig = report.signal       { lines.append("Signal:          \(sig)") }
        if let exc = report.exceptionType { lines.append("Exception Type:  \(exc)") }
        if let th  = report.faultingThread { lines.append("Faulting Thread: \(th)") }

        if let frames = report.stackTrace, !frames.isEmpty {
            lines.append("")
            lines.append("Stack Trace:")
            lines.append(String(repeating: "─", count: 60))
            for (i, frame) in frames.enumerated() {
                var line = String(format: "  %3d", i)
                if let sym = frame.symbol       { line += "  \(sym)" }
                if let off = frame.imageOffset  { line += " + \(off)" }
                if let file = frame.sourceFile, let ln = frame.sourceLine {
                    line += "  (\(file):\(ln))"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension CGSize {
    var asRect: CGRect { CGRect(origin: .zero, size: self) }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd AgenticDaemon && swift build --target AgenticMenuBarLib
```

Expected: builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Sources/AgenticMenuBarLib/CrashDetailWindow.swift
git commit -m "feat: add CrashDetailWindow for full crash report display"
```

---

## Task 12: Create `AppDelegate` and `main.swift`

**Files:**
- Create: `AgenticDaemon/Sources/AgenticMenuBarLib/AppDelegate.swift`
- Create: `AgenticDaemon/Sources/AgenticMenuBar/main.swift`

- [ ] **Step 1: Create `AppDelegate.swift`**

```swift
// Sources/AgenticMenuBarLib/AppDelegate.swift
import AppKit
import Foundation
import os

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "MenuBarApp"
    )

    private var statusItem: NSStatusItem!
    private let client = DaemonClient()
    private var menuBuilder: MenuBuilder!
    private var refreshTimer: Timer?
    private var lastStatus: DaemonStatus?
    private var lastCrashes: [CrashReport] = []

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⚙"
        statusItem.button?.toolTip = "agentic-daemon"

        menuBuilder = MenuBuilder(handlers: makeHandlers())
        client.connect()

        startRefreshTimer()
        Task { await refresh() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        client.disconnect()
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func refresh() async {
        // If not connected, try to connect first
        if !client.isConnected { client.connect() }

        do {
            async let statusFetch = client.getDaemonStatus()
            async let crashFetch  = client.getCrashReports()
            lastStatus = try await statusFetch
            lastCrashes = try await crashFetch
        } catch {
            lastStatus = nil
            lastCrashes = []
        }

        rebuildMenu()
        updateStatusIcon()
    }

    private func rebuildMenu() {
        let menu = menuBuilder.build(status: lastStatus, crashes: lastCrashes)
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        let hasActiveCrashes = !lastCrashes.isEmpty
        let isDaemonRunning = lastStatus != nil
        if !isDaemonRunning {
            statusItem.button?.title = "⚙"
            statusItem.button?.contentTintColor = .systemRed
        } else if hasActiveCrashes {
            statusItem.button?.title = "⚙"
            statusItem.button?.contentTintColor = .systemOrange
        } else {
            statusItem.button?.title = "⚙"
            statusItem.button?.contentTintColor = nil
        }
    }

    // MARK: - Handlers

    private func makeHandlers() -> MenuBuilder.Handlers {
        MenuBuilder.Handlers(
            onTriggerJob: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.triggerJob(name)
                    await self?.refresh()
                }
            },
            onEnableJob: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.enableJob(name)
                    await self?.refresh()
                }
            },
            onDisableJob: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.disableJob(name)
                    await self?.refresh()
                }
            },
            onClearBlacklist: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.clearBlacklist(name)
                    await self?.refresh()
                }
            },
            onShowCrash: { report in
                Task { @MainActor in CrashDetailWindow.show(report: report) }
            },
            onStartDaemon: {
                let label = "com.agentic-cookbook.daemon"
                _ = try? Process.run(
                    URL(fileURLWithPath: "/bin/launchctl"),
                    arguments: ["start", label]
                )
            },
            onStopDaemon: { [weak self] in
                Task { @MainActor in try? await self?.client.shutdown() }
            },
            onRestartDaemon: { [weak self] in
                Task { @MainActor in
                    try? await self?.client.shutdown()
                    try? await Task.sleep(for: .seconds(2))
                    let label = "com.agentic-cookbook.daemon"
                    _ = try? Process.run(
                        URL(fileURLWithPath: "/bin/launchctl"),
                        arguments: ["start", label]
                    )
                    self?.client.connect()
                    await self?.refresh()
                }
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
    }
}
```

- [ ] **Step 2: Create `main.swift`**

```swift
// Sources/AgenticMenuBar/main.swift
import AppKit
import AgenticMenuBarLib

NSApplication.shared.setActivationPolicy(.accessory)
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
```

- [ ] **Step 3: Build the companion binary**

```bash
cd AgenticDaemon && swift build --target AgenticMenuBar
```

Expected: builds cleanly and produces `AgenticMenuBar` binary.

- [ ] **Step 4: Run all tests**

```bash
cd AgenticDaemon && swift test
```

Expected: all tests pass across both test targets.

- [ ] **Step 5: Commit**

```bash
git add AgenticDaemon/Sources/AgenticMenuBarLib/AppDelegate.swift \
    AgenticDaemon/Sources/AgenticMenuBar/main.swift
git commit -m "feat: add AppDelegate and main.swift for menu bar companion"
```

---

## Task 13: Create companion LaunchAgent plist

**Files:**
- Create: `com.agentic-cookbook.menubar.plist`

- [ ] **Step 1: Create `com.agentic-cookbook.menubar.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agentic-cookbook.menubar</string>

    <key>ProgramArguments</key>
    <array>
        <string>${HOME}/Library/Application Support/com.agentic-cookbook.daemon/agentic-menubar</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>WorkingDirectory</key>
    <string>${HOME}/Library/Application Support/com.agentic-cookbook.daemon</string>

    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/com.agentic-cookbook.daemon/menubar-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/com.agentic-cookbook.daemon/menubar-stderr.log</string>
</dict>
</plist>
```

Note: `KeepAlive.SuccessfulExit = false` means launchd restarts the companion only if it crashes, not on a clean quit (so "Quit" from the menu actually quits).

- [ ] **Step 2: Commit**

```bash
git add com.agentic-cookbook.menubar.plist
git commit -m "feat: add companion LaunchAgent plist"
```

---

## Task 14: Update `install.sh`

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Update `install.sh` to build and install the companion**

Replace the full contents of `install.sh`:

```bash
#!/bin/bash
set -euo pipefail

DAEMON_LABEL="com.agentic-cookbook.daemon"
MENUBAR_LABEL="com.agentic-cookbook.menubar"
SUPPORT="$HOME/Library/Application Support/$DAEMON_LABEL"
LOGS="$HOME/Library/Logs/$DAEMON_LABEL"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_PLIST_SRC="$SCRIPT_DIR/${DAEMON_LABEL}.plist"
DAEMON_PLIST_DST="$HOME/Library/LaunchAgents/${DAEMON_LABEL}.plist"
MENUBAR_PLIST_SRC="$SCRIPT_DIR/${MENUBAR_LABEL}.plist"
MENUBAR_PLIST_DST="$HOME/Library/LaunchAgents/${MENUBAR_LABEL}.plist"
PKG_DIR="$SCRIPT_DIR/AgenticDaemon"

echo "Building agentic-daemon and agentic-menubar..."
cd "$PKG_DIR"
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)
DAEMON_BINARY="$BIN_PATH/agentic-daemon"
MENUBAR_BINARY="$BIN_PATH/AgenticMenuBar"

echo "Installing..."
mkdir -p "$SUPPORT/jobs"
mkdir -p "$SUPPORT/lib/Modules"
mkdir -p "$LOGS"

# Install daemon binary
cp "$DAEMON_BINARY" "$SUPPORT/agentic-daemon"
chmod 755 "$SUPPORT/agentic-daemon"

# Install menu bar companion binary
cp "$MENUBAR_BINARY" "$SUPPORT/agentic-menubar"
chmod 755 "$SUPPORT/agentic-menubar"

# Install AgenticJobKit shared library + module for job compilation
cp "$BIN_PATH/libAgenticJobKit.dylib" "$SUPPORT/lib/"
for ext in swiftmodule swiftdoc abi.json swiftsourceinfo; do
    src="$BIN_PATH/Modules/AgenticJobKit.$ext"
    [ -f "$src" ] && cp "$src" "$SUPPORT/lib/Modules/"
done

# Install daemon LaunchAgent plist
sed "s|\${HOME}|$HOME|g" "$DAEMON_PLIST_SRC" > "$DAEMON_PLIST_DST"

# Install menubar LaunchAgent plist
sed "s|\${HOME}|$HOME|g" "$MENUBAR_PLIST_SRC" > "$MENUBAR_PLIST_DST"

# Unload existing agents if running
launchctl bootout "gui/$(id -u)/${DAEMON_LABEL}"  2>/dev/null || true
launchctl bootout "gui/$(id -u)/${MENUBAR_LABEL}" 2>/dev/null || true

# Load and start both agents
launchctl bootstrap "gui/$(id -u)" "$DAEMON_PLIST_DST"
launchctl bootstrap "gui/$(id -u)" "$MENUBAR_PLIST_DST"

echo ""
echo "Installed: $DAEMON_LABEL"
echo "  Binary:  $SUPPORT/agentic-daemon"
echo "  JobKit:  $SUPPORT/lib/libAgenticJobKit.dylib"
echo "  Jobs:    $SUPPORT/jobs/"
echo "  Logs:    $LOGS/"
echo "  Plist:   $DAEMON_PLIST_DST"
echo ""
echo "Installed: $MENUBAR_LABEL"
echo "  Binary:  $SUPPORT/agentic-menubar"
echo "  Plist:   $MENUBAR_PLIST_DST"
echo ""
launchctl list "$DAEMON_LABEL"
launchctl list "$MENUBAR_LABEL"
```

- [ ] **Step 2: Run the full test suite one final time**

```bash
cd AgenticDaemon && swift test
```

Expected: all tests pass.

- [ ] **Step 3: Do a release build to confirm both binaries compile**

```bash
cd AgenticDaemon && swift build -c release
```

Expected: builds cleanly, no warnings.

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat: update install.sh to build and install agentic-menubar"
```

---

## Task 15: Final push and draft PR

- [ ] **Step 1: Push the branch**

```bash
git push
```

- [ ] **Step 2: Open a draft PR**

```bash
gh pr create \
  --title "feat: add AgenticMenuBar companion app with XPC" \
  --draft \
  --body "$(cat <<'EOF'
## Summary

- Adds `AgenticXPCProtocol` shared library with `@objc AgenticDaemonXPC` protocol and shared Codable types (`DaemonStatus`, `JobConfig`, `CrashReport`)
- Adds `XPCServer` + `XPCHandler` to daemon; wires into `DaemonController`; adds `MachServices` key to launchd plist
- Adds `Scheduler.triggerJob(name:)` method
- Adds `AgenticMenuBarLib` + `AgenticMenuBar` companion LSUIElement app with:
  - `DaemonClient` — async XPC wrapper with auto-reconnect
  - `MenuBuilder` — full menu with job submenus, crash list, daemon controls
  - `CrashDetailWindow` — scrollable crash report viewer
  - `AppDelegate` — 5s refresh timer, status icon tinting
- Updates `install.sh` to build + install both binaries and both LaunchAgent plists

## Test plan

- [ ] `swift test` passes all tests (both `AgenticDaemonTests` and `AgenticMenuBarTests`)
- [ ] `swift build -c release` succeeds
- [ ] `./install.sh` installs and starts both LaunchAgents
- [ ] Menu bar icon appears after install
- [ ] Jobs are listed with correct status, next-run countdown, and config
- [ ] Trigger Now advances a job's next run time immediately
- [ ] Disable/Enable job persists across daemon restart
- [ ] Crash detail window opens with correct content
- [ ] Stop Daemon removes the menu bar's live data (shows "not running")
- [ ] Start Daemon restores the connection

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: draft PR URL printed to stdout.
