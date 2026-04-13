import Foundation
import os
import AgenticXPCProtocol
import DaemonKit

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
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] error in
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
