import Foundation

/// Wraps NSXPCConnection for CLI tools. Provides typed proxy access to a
/// daemon's XPC protocol.
///
/// Usage:
/// ```swift
/// let conn = DaemonConnection(machServiceName: "com.example.my-daemon.xpc")
/// conn.connect()
/// let proxy = try conn.xpcProxy(as: MyDaemonXPC.self)
/// // call proxy methods...
/// ```
public final class DaemonConnection: @unchecked Sendable {
    private let machServiceName: String
    private var connection: NSXPCConnection?

    public init(machServiceName: String) {
        self.machServiceName = machServiceName
    }

    public var isConnected: Bool { connection != nil }

    /// Open the XPC connection. Safe to call multiple times.
    public func connect() {
        guard connection == nil else { return }
        let conn = NSXPCConnection(machServiceName: machServiceName)
        conn.invalidationHandler = { [weak self] in self?.connection = nil }
        conn.interruptionHandler = { [weak self] in self?.connection = nil }
        conn.resume()
        connection = conn
    }

    /// Close the XPC connection.
    public func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    /// Set the remote object interface. Call before `xpcProxy(as:)`.
    public func setInterface(_ interface: NSXPCInterface) {
        connection?.remoteObjectInterface = interface
    }

    /// Get the remote proxy, cast to the specified protocol type.
    public func xpcProxy<T>(as type: T.Type) throws -> T {
        guard let conn = connection else {
            throw DaemonConnectionError.notConnected
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            fputs("XPC error: \(error.localizedDescription)\n", stderr)
        }) as? T else {
            throw DaemonConnectionError.proxyUnavailable
        }
        return proxy
    }
}

public enum DaemonConnectionError: Error {
    case notConnected
    case proxyUnavailable
}
