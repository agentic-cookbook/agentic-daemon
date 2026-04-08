// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgenticDaemon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgenticJobKit", type: .dynamic, targets: ["AgenticJobKit"])
    ],
    targets: [
        .target(
            name: "AgenticJobKit",
            path: "Sources/AgenticJobKit"
        ),
        .target(
            name: "AgenticDaemonLib",
            dependencies: ["AgenticJobKit"],
            path: "Sources/AgenticDaemonLib"
        ),
        .executableTarget(
            name: "agentic-daemon",
            dependencies: ["AgenticDaemonLib"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "AgenticDaemonTests",
            dependencies: ["AgenticDaemonLib", "AgenticJobKit"],
            path: "Tests"
        )
    ]
)
