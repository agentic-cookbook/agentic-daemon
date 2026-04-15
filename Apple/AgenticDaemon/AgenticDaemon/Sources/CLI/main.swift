import Foundation
import os
import AgenticDaemonLib

let logger = Logger(
    subsystem: "com.agentic-cookbook.daemon",
    category: "main"
)

let controller = AgenticDaemonController()

signal(SIGTERM) { _ in
    controller.shutdown()
}

signal(SIGINT) { _ in
    controller.shutdown()
}

logger.info("agentic-daemon starting")
await controller.run()
