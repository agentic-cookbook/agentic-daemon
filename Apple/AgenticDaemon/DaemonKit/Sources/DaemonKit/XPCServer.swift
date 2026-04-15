import Foundation
import os

/// A generic NSXPCListener wrapper. The client provides the Mach service name,
/// the XPC interface, and the exported object. DaemonKit has no opinion about
/// what the XPC protocol does.
public final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let logger: Logger
    private let listener: NSXPCListener
    private let interface: NSXPCInterface
    private let exportedObject: AnyObject
    private let serviceName: String

    public init(
        machServiceName: String,
        interface: NSXPCInterface,
        exportedObject: AnyObject,
        subsystem: String
    ) {
        self.logger = Logger(subsystem: subsystem, category: "XPCServer")
        self.serviceName = machServiceName
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.interface = interface
        self.exportedObject = exportedObject
    }

    public func start() {
        listener.delegate = self
        listener.resume()
        logger.info("XPC server listening on \(self.serviceName)")
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = interface
        connection.exportedObject = exportedObject
        connection.resume()
        logger.info("XPC client connected")
        return true
    }
}
