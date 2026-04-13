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
