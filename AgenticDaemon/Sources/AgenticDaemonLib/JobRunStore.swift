import Foundation
import SQLite3
import os

public final class JobRunStore: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "JobRunStore"
    )
    private let queue = DispatchQueue(
        label: "com.agentic-cookbook.daemon.job-run-store",
        qos: .utility
    )
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
            _insert(run)
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
            result = _query(sql: sql) { stmt in
                sqlite3_bind_text(stmt, 1, jobName, -1, Self.transient)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }
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
            result = _query(sql: sql) { stmt in
                sqlite3_bind_int(stmt, 1, Int32(limit))
            }
        }
        return result
    }

    public func cleanup(retentionDays: Int = 30) {
        queue.async { [self] in
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            let sql = "DELETE FROM job_runs WHERE started_at < ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let iso = iso8601()
            sqlite3_bind_text(stmt, 1, iso.string(from: cutoff), -1, Self.transient)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Private

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func iso8601() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    private func configure() throws {
        let pragmas = ["PRAGMA journal_mode=WAL", "PRAGMA foreign_keys=ON"]
        for pragma in pragmas {
            guard sqlite3_exec(db, pragma, nil, nil, nil) == SQLITE_OK else {
                throw JobRunStoreError.configureFailed(pragma)
            }
        }
        let ddl = """
            CREATE TABLE IF NOT EXISTS job_runs (
                id               TEXT PRIMARY KEY,
                job_name         TEXT NOT NULL,
                started_at       TEXT NOT NULL,
                ended_at         TEXT NOT NULL,
                duration_seconds REAL NOT NULL,
                success          INTEGER NOT NULL,
                error_message    TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_job_runs_job_name   ON job_runs(job_name);
            CREATE INDEX IF NOT EXISTS idx_job_runs_started_at ON job_runs(started_at);
        """
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
            throw JobRunStoreError.configureFailed("CREATE TABLE")
        }
    }

    private func _insert(_ run: JobRun) {
        let sql = """
            INSERT OR IGNORE INTO job_runs
                (id, job_name, started_at, ended_at, duration_seconds, success, error_message)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let iso = iso8601()
        sqlite3_bind_text(stmt, 1, run.id.uuidString, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, run.jobName, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, iso.string(from: run.startedAt), -1, Self.transient)
        sqlite3_bind_text(stmt, 4, iso.string(from: run.endedAt), -1, Self.transient)
        sqlite3_bind_double(stmt, 5, run.durationSeconds)
        sqlite3_bind_int(stmt, 6, run.success ? 1 : 0)
        if let msg = run.errorMessage {
            sqlite3_bind_text(stmt, 7, msg, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        sqlite3_step(stmt)
    }

    private func _query(sql: String, bind: (OpaquePointer) -> Void) -> [JobRun] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let iso = iso8601()
        var runs: [JobRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idStr    = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                let id       = UUID(uuidString: idStr),
                let jobName  = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                let startStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                let endStr   = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                let startedAt = iso.date(from: startStr),
                let endedAt   = iso.date(from: endStr)
            else { continue }
            let duration     = sqlite3_column_double(stmt, 4)
            let success      = sqlite3_column_int(stmt, 5) != 0
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
