// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgenticDaemon",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "AgenticDaemonLib",
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
            path: "Tests"
        )
    ]
)
