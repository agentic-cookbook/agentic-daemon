# Operational Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port job execution history (SQLite), an HTTP management API, an XPC service, and a dev-reload test from claude-watcher into agentic-daemon.

**Architecture:** `JobRunStore` records every job execution to SQLite; `HTTPServer`/`HTTPRouter` expose that data plus live scheduler state on `localhost:22846`; `XPCService` registers a Mach service so future Swift clients can query the daemon without HTTP; `agenticd` Python CLI prefers the HTTP API and falls back to file reads. `test_dev_reload.py` validates the dev-reload script end-to-end.

**Tech Stack:** Swift 6, Network.framework, SQLite3 (system library via linker flag), NSXPCListener/NSXPCConnection, Python 3 (tests + CLI).

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `AgenticDaemon/Sources/AgenticDaemonLib/JobRun.swift` | `JobRun` Codable model |
| Create | `AgenticDaemon/Sources/AgenticDaemonLib/JobRunStore.swift` | SQLite store: insert + query job runs |
| Create | `AgenticDaemon/Sources/AgenticDaemonLib/HTTPServer.swift` | NWListener, localhost-only HTTP/1.1 |
| Create | `AgenticDaemon/Sources/AgenticDaemonLib/HTTPRouter.swift` | Route requests → JSON responses |
| Create | `AgenticDaemon/Sources/AgenticDaemonLib/XPCProtocol.swift` | `@objc protocol AgenticDaemonXPCProtocol` |
| Create | `AgenticDaemon/Sources/AgenticDaemonLib/XPCService.swift` | `NSXPCListener` setup + protocol impl |
| Create | `AgenticDaemon/Tests/JobRunStoreTests.swift` | Unit tests for store |
| Create | `AgenticDaemon/Tests/HTTPRouterTests.swift` | Unit tests for router |
| Create | `tests/test_dev_reload.py` | End-to-end dev-reload test |
| Modify | `AgenticDaemon/Package.swift` | Add `linkerSettings: [.linkedLibrary("sqlite3")]` |
| Modify | `AgenticDaemon/Sources/AgenticDaemonLib/Scheduler.swift` | Accept `JobRunStore?`, record runs |
| Modify | `AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift` | Init store, HTTP server, XPC service |
| Modify | `com.agentic-cookbook.daemon.plist` | Add `MachServices` key |
| Modify | `agenticd` | HTTP-first queries, fall back to files |

---

## Task 1: JobRun model

**Files:**
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/JobRun.swift`

- [ ] **Step 1: Create the model**

```swift
// AgenticDaemon/Sources/AgenticDaemonLib/JobRun.swift
import Foundation

public struct JobRun: Codable, Sendable {
    public let id: UUID
    public let jobName: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: Double
    public let success: Bool
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        jobName: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.jobName = jobName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.success = success
        self.errorMessage = errorMessage
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build --package-path AgenticDaemon 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/JobRun.swift
git commit -m "feat: add JobRun model"
```

---

## Task 2: Package.swift — link SQLite3

**Files:**
- Modify: `AgenticDaemon/Package.swift`

- [ ] **Step 1: Add linkerSettings to AgenticDaemonLib target**

Change the `AgenticDaemonLib` target from:
```swift
.target(
    name: "AgenticDaemonLib",
    dependencies: [
        "AgenticJobKit",
        .product(name: "CrashReporter", package: "plcrashreporter")
    ],
    path: "Sources/AgenticDaemonLib"
),
```
To:
```swift
.target(
    name: "AgenticDaemonLib",
    dependencies: [
        "AgenticJobKit",
        .product(name: "CrashReporter", package: "plcrashreporter")
    ],
    path: "Sources/AgenticDaemonLib",
    linkerSettings: [.linkedLibrary("sqlite3")]
),
```

- [ ] **Step 2: Build to confirm SQLite3 links**

```bash
swift build --package-path AgenticDaemon 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Package.swift
git commit -m "feat: link SQLite3 system library"
```

---

## Task 3: JobRunStore

**Files:**
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/JobRunStore.swift`
- Create: `AgenticDaemon/Tests/JobRunStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// AgenticDaemon/Tests/JobRunStoreTests.swift
import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite struct JobRunStoreTests {
    func makeStore() throws -> JobRunStore {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "runs-\(UUID().uuidString).db")
        return try JobRunStore(databaseURL: tmp)
    }

    @Test func recordAndQuery() throws {
        let store = try makeStore()
        let run = JobRun(
            jobName: "test-job",
            startedAt: Date(timeIntervalSinceNow: -5),
            endedAt: Date(),
            durationSeconds: 5.0,
            success: true
        )
        store.record(run)
        let runs = store.runs(for: "test-job", limit: 10)
        #expect(runs.count == 1)
        #expect(runs[0].jobName == "test-job")
        #expect(runs[0].success == true)
    }

    @Test func queryReturnsNewestFirst() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSinceNow: -100)
        for i in 0..<5 {
            let run = JobRun(
                jobName: "j",
                startedAt: base.addingTimeInterval(Double(i * 10)),
                endedAt: base.addingTimeInterval(Double(i * 10 + 1)),
                durationSeconds: 1.0,
                success: true
            )
            store.record(run)
        }
        let runs = store.runs(for: "j", limit: 10)
        #expect(runs.count == 5)
        #expect(runs[0].startedAt >= runs[1].startedAt)
    }

    @Test func limitIsRespected() throws {
        let store = try makeStore()
        for _ in 0..<20 {
            let run = JobRun(
                jobName: "j",
                startedAt: Date(timeIntervalSinceNow: -1),
                endedAt: Date(),
                durationSeconds: 1.0,
                success: true
            )
            store.record(run)
        }
        let runs = store.runs(for: "j", limit: 5)
        #expect(runs.count == 5)
    }

    @Test func recentRunsAcrossJobs() throws {
        let store = try makeStore()
        for name in ["a", "b", "c"] {
            let run = JobRun(
                jobName: name,
                startedAt: Date(timeIntervalSinceNow: -1),
                endedAt: Date(),
                durationSeconds: 1.0,
                success: true
            )
            store.record(run)
        }
        let runs = store.recentRuns(limit: 10)
        #expect(runs.count == 3)
    }

    @Test func cleanupRemovesOldRuns() throws {
        let store = try makeStore()
        // old run: 31 days ago
        let old = JobRun(
            jobName: "j",
            startedAt: Date(timeIntervalSinceNow: -31 * 86400),
            endedAt: Date(timeIntervalSinceNow: -31 * 86400 + 1),
            durationSeconds: 1.0,
            success: true
        )
        // recent run: now
        let recent = JobRun(
            jobName: "j",
            startedAt: Date(timeIntervalSinceNow: -1),
            endedAt: Date(),
            durationSeconds: 1.0,
            success: true
        )
        store.record(old)
        store.record(recent)
        store.cleanup(retentionDays: 30)
        let runs = store.runs(for: "j", limit: 10)
        #expect(runs.count == 1)
        #expect(runs[0].success == true)
    }
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
swift test --package-path AgenticDaemon --filter JobRunStoreTests 2>&1 | tail -10
```
Expected: compile error — `JobRunStore` not found.

- [ ] **Step 3: Implement JobRunStore**

```swift
// AgenticDaemon/Sources/AgenticDaemonLib/JobRunStore.swift
import Foundation
import SQLite3
import os

public final class JobRunStore: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "JobRunStore"
    )
    private let queue = DispatchQueue(label: "com.agentic-cookbook.daemon.job-run-store", qos: .utility)
    private let db: OpaquePointer

    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &handle, flags, nil) == SQLITE_OK,
              let handle else {
            throw JobRunStoreError.openFailed(databaseURL.path(percentEncoded: false))
        }
        db = handle
        try configure()
    }

    deinit {
        sqlite3_close(db)
    }

    public func record(_ run: JobRun) {
        queue.async { [self] in
            let iso = ISO8601DateFormatter()
            let sql = """
                INSERT OR IGNORE INTO job_runs
                    (id, job_name, started_at, ended_at, duration_seconds, success, error_message)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, run.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, run.jobName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, iso.string(from: run.startedAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, iso.string(from: run.endedAt), -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, run.durationSeconds)
            sqlite3_bind_int(stmt, 6, run.success ? 1 : 0)
            if let msg = run.errorMessage {
                sqlite3_bind_text(stmt, 7, msg, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_step(stmt)
        }
    }

    public func runs(for jobName: String, limit: Int = 50) -> [JobRun] {
        var result: [JobRun] = []
        queue.sync { [self] in
            let sql = """
                SELECT id, job_name, started_at, ended_at, duration_seconds, success, error_message
                FROM job_runs
                WHERE job_name = ?
                ORDER BY started_at DESC
                LIMIT ?
            """
            result = _query(sql: sql, bindings: { stmt in
                sqlite3_bind_text(stmt, 1, jobName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            })
        }
        return result
    }

    public func recentRuns(limit: Int = 100) -> [JobRun] {
        var result: [JobRun] = []
        queue.sync { [self] in
            let sql = """
                SELECT id, job_name, started_at, ended_at, duration_seconds, success, error_message
                FROM job_runs
                ORDER BY started_at DESC
                LIMIT ?
            """
            result = _query(sql: sql, bindings: { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            })
        }
        return result
    }

    public func cleanup(retentionDays: Int = 30) {
        queue.async { [self] in
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            let iso = ISO8601DateFormatter()
            let sql = "DELETE FROM job_runs WHERE started_at < ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, iso.string(from: cutoff), -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Private

    private func configure() throws {
        let pragmas = ["PRAGMA journal_mode=WAL", "PRAGMA foreign_keys=ON"]
        for pragma in pragmas {
            if sqlite3_exec(db, pragma, nil, nil, nil) != SQLITE_OK {
                throw JobRunStoreError.configureFailed(pragma)
            }
        }
        let create = """
            CREATE TABLE IF NOT EXISTS job_runs (
                id               TEXT PRIMARY KEY,
                job_name         TEXT NOT NULL,
                started_at       TEXT NOT NULL,
                ended_at         TEXT NOT NULL,
                duration_seconds REAL NOT NULL,
                success          INTEGER NOT NULL,
                error_message    TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_job_runs_job_name ON job_runs(job_name);
            CREATE INDEX IF NOT EXISTS idx_job_runs_started_at ON job_runs(started_at);
        """
        if sqlite3_exec(db, create, nil, nil, nil) != SQLITE_OK {
            throw JobRunStoreError.configureFailed("CREATE TABLE")
        }
    }

    private func _query(sql: String, bindings: (OpaquePointer) -> Void) -> [JobRun] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindings(stmt)
        let iso = ISO8601DateFormatter()
        var runs: [JobRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                let id = UUID(uuidString: idStr),
                let jobName = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                let startedStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                let endedStr = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                let startedAt = iso.date(from: startedStr),
                let endedAt = iso.date(from: endedStr)
            else { continue }
            let duration = sqlite3_column_double(stmt, 4)
            let success = sqlite3_column_int(stmt, 5) != 0
            let errorMessage = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            runs.append(JobRun(
                id: id,
                jobName: jobName,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: duration,
                success: success,
                errorMessage: errorMessage
            ))
        }
        return runs
    }
}

public enum JobRunStoreError: Error {
    case openFailed(String)
    case configureFailed(String)
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
swift test --package-path AgenticDaemon --filter JobRunStoreTests 2>&1 | tail -15
```
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/JobRunStore.swift \
        AgenticDaemon/Tests/JobRunStoreTests.swift
git commit -m "feat: add JobRunStore (SQLite job execution history)"
```

---

## Task 4: Wire JobRunStore into Scheduler

**Files:**
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/Scheduler.swift`

- [ ] **Step 1: Add `jobRunStore` property and update init**

Add to `Scheduler`:
```swift
private let jobRunStore: JobRunStore?
```

Update `init`:
```swift
public init(
    buildDir: URL,
    crashTracker: CrashTracker? = nil,
    analytics: any AnalyticsProvider = LogAnalyticsProvider(),
    jobRunStore: JobRunStore? = nil
) {
    self.compiler = SwiftCompiler(buildDir: buildDir)
    self.crashTracker = crashTracker ?? CrashTracker(stateDir: buildDir)
    self.analytics = analytics
    self.jobRunStore = jobRunStore
}
```

- [ ] **Step 2: Record runs in `runJob`**

In the success branch of `runJob`, after `crashTracker.clearRunning()`, add:
```swift
jobRunStore?.record(JobRun(
    jobName: name,
    startedAt: startTime,
    endedAt: Date.now,
    durationSeconds: duration,
    success: true
))
```

In the failure branch, after `crashTracker.clearRunning()`, add:
```swift
jobRunStore?.record(JobRun(
    jobName: name,
    startedAt: startTime,
    endedAt: Date.now,
    durationSeconds: duration,
    success: false,
    errorMessage: error.localizedDescription
))
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
swift build --package-path AgenticDaemon 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/Scheduler.swift
git commit -m "feat: record job runs in Scheduler"
```

---

## Task 5: Wire JobRunStore into DaemonController

**Files:**
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift`

- [ ] **Step 1: Add store property, init, and pass to Scheduler**

Add property:
```swift
private let jobRunStore: JobRunStore
```

In `init`, after `crashReportStore = ...`:
```swift
let runsDB = supportDirectory.appending(path: "runs.db")
do {
    jobRunStore = try JobRunStore(databaseURL: runsDB)
} catch {
    fatalError("Failed to open job run store: \(error)")
}
```

Update `Scheduler` init call to pass the store:
```swift
scheduler = Scheduler(buildDir: libDir, crashTracker: crashTracker, analytics: analytics, jobRunStore: jobRunStore)
```

In `run()`, after `crashReportStore.cleanup(retentionDays: 30)`, add:
```swift
jobRunStore.cleanup(retentionDays: 30)
```

In `createDirectories()`, the `runs.db` file is created automatically by SQLite — no directory to add.

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build --package-path AgenticDaemon 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift
git commit -m "feat: wire JobRunStore into DaemonController"
```

---

## Task 6: HTTP Server

**Files:**
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/HTTPServer.swift`
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/HTTPRouter.swift`
- Create: `AgenticDaemon/Tests/HTTPRouterTests.swift`

- [ ] **Step 1: Write failing router tests**

```swift
// AgenticDaemon/Tests/HTTPRouterTests.swift
import Testing
import Foundation
@testable import AgenticDaemonLib

@Suite struct HTTPRouterTests {
    func makeRouter() throws -> (HTTPRouter, JobRunStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "runs-\(UUID().uuidString).db")
        let store = try JobRunStore(databaseURL: tmp)
        let tracker = CrashTracker(stateDir: FileManager.default.temporaryDirectory)
        let router = HTTPRouter(
            scheduler: Scheduler(buildDir: FileManager.default.temporaryDirectory),
            jobRunStore: store,
            crashTracker: tracker,
            startTime: Date()
        )
        return (router, store)
    }

    @Test func healthReturnsOK() async throws {
        let (router, _) = try makeRouter()
        let response = await router.handle(method: "GET", path: "/health", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(json?["status"] as? String == "ok")
    }

    @Test func unknownPathReturns404() async throws {
        let (router, _) = try makeRouter()
        let response = await router.handle(method: "GET", path: "/nonexistent", body: nil)
        #expect(response.status == 404)
    }

    @Test func jobsReturnsArray() async throws {
        let (router, _) = try makeRouter()
        let response = await router.handle(method: "GET", path: "/jobs", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        #expect(json != nil)
    }

    @Test func runsEndpointReturnsArray() async throws {
        let (router, store) = try makeRouter()
        let run = JobRun(
            jobName: "my-job",
            startedAt: Date(timeIntervalSinceNow: -5),
            endedAt: Date(),
            durationSeconds: 5.0,
            success: true
        )
        store.record(run)
        try await Task.sleep(for: .milliseconds(50)) // let async write complete
        let response = await router.handle(method: "GET", path: "/jobs/my-job/runs", body: nil)
        #expect(response.status == 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        #expect(json != nil)
    }
}
```

- [ ] **Step 2: Run to confirm it fails**

```bash
swift test --package-path AgenticDaemon --filter HTTPRouterTests 2>&1 | tail -10
```
Expected: compile error — `HTTPRouter` not found.

- [ ] **Step 3: Implement HTTPRouter**

```swift
// AgenticDaemon/Sources/AgenticDaemonLib/HTTPRouter.swift
import Foundation
import os

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, body: data, contentType: "application/json")
    }

    public static func notFound() -> HTTPResponse {
        HTTPResponse(status: 404, body: Data("{\"error\":\"not found\"}".utf8), contentType: "application/json")
    }
}

public struct HTTPRouter: Sendable {
    private let logger = Logger(subsystem: "com.agentic-cookbook.daemon", category: "HTTPRouter")
    let scheduler: Scheduler
    let jobRunStore: JobRunStore
    let crashTracker: CrashTracker
    let startTime: Date

    public init(
        scheduler: Scheduler,
        jobRunStore: JobRunStore,
        crashTracker: CrashTracker,
        startTime: Date
    ) {
        self.scheduler = scheduler
        self.jobRunStore = jobRunStore
        self.crashTracker = crashTracker
        self.startTime = startTime
    }

    public func handle(method: String, path: String, body: Data?) async -> HTTPResponse {
        logger.debug("\(method) \(path)")
        switch (method, path) {
        case ("GET", "/health"):
            return await handleHealth()
        case ("GET", "/jobs"):
            return await handleJobs()
        case ("GET", "/runs"):
            return handleRecentRuns()
        case ("GET", let p) where p.hasPrefix("/jobs/") && p.hasSuffix("/runs"):
            let name = String(p.dropFirst("/jobs/".count).dropLast("/runs".count))
            return handleJobRuns(jobName: name)
        case ("GET", let p) where p.hasPrefix("/jobs/"):
            let name = String(p.dropFirst("/jobs/".count))
            return await handleJob(name: name)
        default:
            return .notFound()
        }
    }

    // MARK: - Handlers

    private struct HealthResponse: Encodable {
        let status: String
        let uptimeSeconds: Double
        let jobCount: Int
        let version: String
    }

    private func handleHealth() async -> HTTPResponse {
        let uptime = Date().timeIntervalSince(startTime)
        let count = await scheduler.jobCount
        return .json(HealthResponse(status: "ok", uptimeSeconds: uptime, jobCount: count, version: "1.0.0"))
    }

    private struct JobSummary: Encodable {
        let name: String
        let nextRun: Date
        let consecutiveFailures: Int
        let isRunning: Bool
        let isBlacklisted: Bool
    }

    private func handleJobs() async -> HTTPResponse {
        let names = await scheduler.jobNames
        var summaries: [JobSummary] = []
        for name in names.sorted() {
            guard let job = await scheduler.job(named: name) else { continue }
            summaries.append(JobSummary(
                name: name,
                nextRun: job.nextRun,
                consecutiveFailures: job.consecutiveFailures,
                isRunning: job.isRunning,
                isBlacklisted: crashTracker.isBlacklisted(jobName: name)
            ))
        }
        return .json(summaries)
    }

    private func handleJob(name: String) async -> HTTPResponse {
        guard let job = await scheduler.job(named: name) else {
            return .notFound()
        }
        struct JobDetail: Encodable {
            let name: String
            let nextRun: Date
            let consecutiveFailures: Int
            let isRunning: Bool
            let isBlacklisted: Bool
            let recentRuns: [JobRun]
        }
        let recentRuns = jobRunStore.runs(for: name, limit: 20)
        return .json(JobDetail(
            name: name,
            nextRun: job.nextRun,
            consecutiveFailures: job.consecutiveFailures,
            isRunning: job.isRunning,
            isBlacklisted: crashTracker.isBlacklisted(jobName: name),
            recentRuns: recentRuns
        ))
    }

    private func handleJobRuns(jobName: String) -> HTTPResponse {
        let runs = jobRunStore.runs(for: jobName, limit: 50)
        return .json(runs)
    }

    private func handleRecentRuns() -> HTTPResponse {
        let runs = jobRunStore.recentRuns(limit: 100)
        return .json(runs)
    }
}
```

- [ ] **Step 4: Implement HTTPServer**

```swift
// AgenticDaemon/Sources/AgenticDaemonLib/HTTPServer.swift
import Foundation
import Network
import os

public final class HTTPServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.agentic-cookbook.daemon", category: "HTTPServer")
    private let router: HTTPRouter
    private var listener: NWListener?
    private let port: UInt16

    public init(router: HTTPRouter, port: UInt16 = 22846) {
        self.router = router
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: .global(qos: .utility))
        logger.info("HTTP server listening on port \(self.port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveRequest(connection: connection)
    }

    private func receiveRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            guard let request = HTTPRequestParser.parse(data) else {
                self.sendResponse(.notFound(), to: connection)
                return
            }
            Task {
                let response = await self.router.handle(
                    method: request.method,
                    path: request.path,
                    body: request.body
                )
                self.sendResponse(response, to: connection)
            }
        }
    }

    private func sendResponse(_ response: HTTPResponse, to connection: NWConnection) {
        let header = """
            HTTP/1.1 \(response.status) \(statusText(response.status))\r\n\
            Content-Type: \(response.contentType)\r\n\
            Content-Length: \(response.body.count)\r\n\
            Connection: close\r\n\
            \r\n
            """
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
}

// MARK: - Request parser

struct ParsedRequest {
    let method: String
    let path: String
    let body: Data?
}

enum HTTPRequestParser {
    static func parse(_ data: Data) -> ParsedRequest? {
        guard let str = String(data: data, encoding: .utf8),
              let headerEnd = str.range(of: "\r\n\r\n") else { return nil }
        let headerSection = String(str[str.startIndex..<headerEnd.lowerBound])
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let fullPath = parts[1]
        let path = fullPath.components(separatedBy: "?").first ?? fullPath
        return ParsedRequest(method: method, path: path, body: nil)
    }
}
```

- [ ] **Step 5: Run router tests**

```bash
swift test --package-path AgenticDaemon --filter HTTPRouterTests 2>&1 | tail -15
```
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/HTTPServer.swift \
        AgenticDaemon/Sources/AgenticDaemonLib/HTTPRouter.swift \
        AgenticDaemon/Tests/HTTPRouterTests.swift
git commit -m "feat: add HTTP management server (port 22846)"
```

---

## Task 7: Wire HTTP server into DaemonController

**Files:**
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift`

- [ ] **Step 1: Add httpServer property**

Add property:
```swift
private let httpServer: HTTPServer
```

In `init`, after `jobRunStore = ...`:
```swift
let router = HTTPRouter(
    scheduler: scheduler,
    jobRunStore: jobRunStore,
    crashTracker: crashTracker,
    startTime: Date()
)
httpServer = HTTPServer(router: router)
```

- [ ] **Step 2: Start HTTP server in `run()`**

After `createDirectories()` in `run()`, add:
```swift
do {
    try httpServer.start()
} catch {
    logger.error("Failed to start HTTP server: \(error)")
}
```

In `shutdown()`, after `running = false`, add:
```swift
httpServer.stop()
```

- [ ] **Step 3: Build and verify**

```bash
swift build --package-path AgenticDaemon 2>&1 | tail -5
swift test --package-path AgenticDaemon 2>&1 | tail -10
```
Expected: builds cleanly, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift
git commit -m "feat: start HTTP server in DaemonController"
```

---

## Task 8: XPC service

**Files:**
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/XPCProtocol.swift`
- Create: `AgenticDaemon/Sources/AgenticDaemonLib/XPCService.swift`
- Modify: `AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift`
- Modify: `com.agentic-cookbook.daemon.plist`

- [ ] **Step 1: Define XPC protocol**

```swift
// AgenticDaemon/Sources/AgenticDaemonLib/XPCProtocol.swift
import Foundation

@objc public protocol AgenticDaemonXPCProtocol {
    func healthCheck(reply: @escaping (Data) -> Void)
    func listJobs(reply: @escaping ([Data]) -> Void)
    func jobRuns(jobName: String, limit: Int, reply: @escaping ([Data]) -> Void)
    func recentRuns(limit: Int, reply: @escaping ([Data]) -> Void)
}
```

- [ ] **Step 2: Implement XPC service**

```swift
// AgenticDaemon/Sources/AgenticDaemonLib/XPCService.swift
import Foundation
import os

public final class XPCService: NSObject, AgenticDaemonXPCProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.agentic-cookbook.daemon", category: "XPCService")
    private let scheduler: Scheduler
    private let jobRunStore: JobRunStore
    private let crashTracker: CrashTracker
    private let startTime: Date
    private var listener: NSXPCListener?

    public init(
        scheduler: Scheduler,
        jobRunStore: JobRunStore,
        crashTracker: CrashTracker,
        startTime: Date
    ) {
        self.scheduler = scheduler
        self.jobRunStore = jobRunStore
        self.crashTracker = crashTracker
        self.startTime = startTime
    }

    public func start() {
        let l = NSXPCListener(machServiceName: "com.agentic-cookbook.daemon")
        l.delegate = XPCListenerDelegate(service: self)
        l.resume()
        listener = l
        logger.info("XPC service registered")
    }

    public func stop() {
        listener?.invalidate()
        listener = nil
    }

    // MARK: - Protocol

    public func healthCheck(reply: @escaping (Data) -> Void) {
        Task { [self] in
            let uptime = Date().timeIntervalSince(startTime)
            let count = await scheduler.jobCount
            let payload: [String: Any] = ["status": "ok", "uptimeSeconds": uptime, "jobCount": count]
            reply((try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }
    }

    public func listJobs(reply: @escaping ([Data]) -> Void) {
        Task { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let names = await scheduler.jobNames
            var items: [Data] = []
            for name in names.sorted() {
                guard let job = await scheduler.job(named: name) else { continue }
                let payload: [String: Any] = [
                    "name": name,
                    "consecutiveFailures": job.consecutiveFailures,
                    "isRunning": job.isRunning,
                    "isBlacklisted": crashTracker.isBlacklisted(jobName: name)
                ]
                if let d = try? JSONSerialization.data(withJSONObject: payload) {
                    items.append(d)
                }
            }
            reply(items)
        }
    }

    public func jobRuns(jobName: String, limit: Int, reply: @escaping ([Data]) -> Void) {
        let runs = jobRunStore.runs(for: jobName, limit: limit)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        reply(runs.compactMap { try? encoder.encode($0) })
    }

    public func recentRuns(limit: Int, reply: @escaping ([Data]) -> Void) {
        let runs = jobRunStore.recentRuns(limit: limit)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        reply(runs.compactMap { try? encoder.encode($0) })
    }
}

// MARK: - Listener delegate

private final class XPCListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let service: XPCService

    init(service: XPCService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AgenticDaemonXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
```

- [ ] **Step 3: Wire XPC service into DaemonController**

Add property:
```swift
private let xpcService: XPCService
```

In `init`, after `httpServer = ...`:
```swift
xpcService = XPCService(
    scheduler: scheduler,
    jobRunStore: jobRunStore,
    crashTracker: crashTracker,
    startTime: Date()
)
```

In `run()`, after `httpServer.start()`:
```swift
xpcService.start()
```

In `shutdown()`:
```swift
xpcService.stop()
```

- [ ] **Step 4: Add MachServices to plist**

In `com.agentic-cookbook.daemon.plist`, add before `</dict>`:
```xml
    <key>MachServices</key>
    <dict>
        <key>com.agentic-cookbook.daemon</key>
        <true/>
    </dict>
```

- [ ] **Step 5: Build and test**

```bash
swift build --package-path AgenticDaemon 2>&1 | tail -5
swift test --package-path AgenticDaemon 2>&1 | tail -10
```
Expected: builds cleanly, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add AgenticDaemon/Sources/AgenticDaemonLib/XPCProtocol.swift \
        AgenticDaemon/Sources/AgenticDaemonLib/XPCService.swift \
        AgenticDaemon/Sources/AgenticDaemonLib/DaemonController.swift \
        com.agentic-cookbook.daemon.plist
git commit -m "feat: add XPC service (com.agentic-cookbook.daemon Mach service)"
```

---

## Task 9: Update agenticd to query HTTP API

**Files:**
- Modify: `agenticd`

- [ ] **Step 1: Add HTTP client helpers at top of agenticd**

Add after the imports:
```python
HTTP_BASE = "http://localhost:22846"

def _http_get(path: str) -> dict | list | None:
    """Try HTTP API; return parsed JSON or None on any failure."""
    import urllib.request
    import urllib.error
    try:
        with urllib.request.urlopen(f"{HTTP_BASE}{path}", timeout=2) as r:
            return json.loads(r.read())
    except Exception:
        return None
```

- [ ] **Step 2: Update `cmd_status` to prefer HTTP**

Replace the `status = _load_status()` block with:
```python
http_health = _http_get("/health")
status = http_health or _load_status()
live = http_health is not None
```

Update the uptime/job count display to use `http_health` keys when available:
```python
if status:
    uptime = _uptime_str(status.get("uptimeSeconds", 0))
    job_count = status.get("jobCount", 0)
    source = "" if live else _fmt(_dim, " (cached)")
    print(f"  uptime: {uptime}  jobs: {job_count}{source}")
```

- [ ] **Step 3: Update `cmd_jobs` to prefer HTTP**

Replace the `status = _load_status()` call with:
```python
http_jobs = _http_get("/jobs")
if http_jobs is not None:
    # HTTP returns list directly
    jobs = http_jobs
    blacklist = _load_blacklist()
    if not jobs:
        print("No jobs discovered.")
        print(_fmt(_dim, f"  Drop a job.swift into {SUPPORT / 'jobs'}/"))
        return
    print(_fmt(_bold, f"{'NAME':<24} {'NEXT RUN':<16} {'FAILURES':<10} {'STATE'}"))
    print("─" * 64)
    for job in sorted(jobs, key=lambda j: j["name"]):
        name = job["name"]
        next_run = _rel_time(job.get("nextRun", ""))
        failures = job.get("consecutiveFailures", 0)
        is_running = job.get("isRunning", False)
        is_blacklisted = job.get("isBlacklisted", name in blacklist)
        if is_blacklisted:
            state = _fmt(_red, "blacklisted")
        elif is_running:
            state = _fmt(_green, "running")
        elif failures > 0:
            state = _fmt(_yellow, "backing off")
        else:
            state = _fmt(_dim, "idle")
        fail_str = _fmt(_yellow, str(failures)) if failures > 0 else str(failures)
        print(f"  {name:<22} {next_run:<16} {fail_str:<10} {state}")
    print()
    return
# fall back to status.json
status = _load_status()
```
(keep the existing file-based fallback below this early return)

- [ ] **Step 4: Add `cmd_runs` command**

Add a new command that queries `/runs` or `/jobs/:name/runs`:
```python
def cmd_runs() -> None:
    args = sys.argv[2:]  # agenticd runs [job-name]
    if args:
        data = _http_get(f"/jobs/{args[0]}/runs")
        if data is None:
            print(_fmt(_yellow, "HTTP API unavailable. Run history requires the daemon to be running."))
            return
        runs = data
        title = f"Runs for {args[0]}"
    else:
        data = _http_get("/runs")
        if data is None:
            print(_fmt(_yellow, "HTTP API unavailable. Run history requires the daemon to be running."))
            return
        runs = data
        title = "Recent runs (all jobs)"

    if not runs:
        print("No runs recorded yet.")
        return

    print(_fmt(_bold, title))
    print(_fmt(_bold, f"{'TIME':<16} {'JOB':<24} {'DURATION':<12} {'RESULT'}"))
    print("─" * 68)
    for r in runs:
        ts = _rel_time(r.get("startedAt", ""))
        job = r.get("jobName", "?")
        dur = f"{r.get('durationSeconds', 0):.2f}s"
        success = r.get("success", False)
        result = _fmt(_green, "ok") if success else _fmt(_red, "failed")
        if r.get("errorMessage"):
            result += _fmt(_dim, f"  {r['errorMessage'][:40]}")
        print(f"  {ts:<14} {job:<24} {dur:<12} {result}")
    print()
```

Add `"runs": cmd_runs` to the `COMMANDS` dict and update `usage()` to include it.

- [ ] **Step 5: Verify agenticd still works without the daemon running**

```bash
./agenticd status
./agenticd jobs
./agenticd crashes
```
Expected: graceful fallback to file reads, no traceback.

- [ ] **Step 6: Commit**

```bash
git add agenticd
git commit -m "feat: agenticd queries HTTP API with file fallback, adds runs command"
```

---

## Task 10: test_dev_reload.py

**Files:**
- Create: `tests/test_dev_reload.py`

- [ ] **Step 1: Create the test**

```python
#!/usr/bin/env python3
"""
End-to-end tests for dev-reload.py.

Validates: build → bootstrap → PID visible → kickstart → PID visible → cleanup.

Usage:
    python3 tests/test_dev_reload.py
"""
import subprocess
import sys
import time
from pathlib import Path

LABEL = "com.agentic-cookbook.daemon"
repo = Path(__file__).parent.parent.resolve()
dev_reload = repo / "dev-reload.py"


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), capture_output=True, text=True, check=check)


def daemon_pid() -> str:
    result = run("launchctl", "list", LABEL, check=False)
    if result.returncode != 0:
        return ""
    for line in result.stdout.splitlines():
        if '"PID"' in line:
            return line.split()[-1].rstrip(",").strip('"')
    return ""


def wait_for_pid(timeout: int = 15) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = daemon_pid()
        if pid:
            return pid
        time.sleep(0.5)
    return ""


def bootout() -> None:
    run("launchctl", "bootout", f"gui/{__import__('os').getuid()}/{LABEL}", check=False)
    time.sleep(1)


def test_full_reload() -> None:
    print("test_full_reload: build + bootstrap + verify PID ...")
    result = subprocess.run(
        [sys.executable, str(dev_reload)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("FAIL: dev-reload.py exited non-zero")
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    pid = wait_for_pid()
    if not pid:
        print("FAIL: no PID after full reload")
        sys.exit(1)
    print(f"  PASS (PID {pid})")


def test_quick_reload() -> None:
    print("test_quick_reload: kickstart without rebuild ...")
    result = subprocess.run(
        [sys.executable, str(dev_reload), "--quick"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print("FAIL: dev-reload.py --quick exited non-zero")
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    pid = wait_for_pid()
    if not pid:
        print("FAIL: no PID after quick reload")
        sys.exit(1)
    print(f"  PASS (PID {pid})")


def cleanup() -> None:
    print("cleanup: stopping dev daemon ...")
    bootout()
    print("  done")


def main() -> None:
    try:
        test_full_reload()
        test_quick_reload()
    finally:
        cleanup()
    print()
    print("All dev-reload tests passed.")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Commit**

```bash
git add tests/test_dev_reload.py
git commit -m "feat: add dev-reload end-to-end test"
```

---

## Task 11: Final check and push

- [ ] **Step 1: Run full test suite**

```bash
swift test --package-path AgenticDaemon 2>&1 | tail -20
```
Expected: all tests pass.

- [ ] **Step 2: Verify agenticd syntax**

```bash
python3 -m py_compile agenticd && echo "ok"
```
Expected: `ok`

- [ ] **Step 3: Push branch**

```bash
git push
```
