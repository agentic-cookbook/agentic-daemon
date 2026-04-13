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
    dependencies: [
        .package(url: "git@github.com:microsoft/plcrashreporter.git", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "AgenticJobKit",
            path: "Sources/AgenticJobKit"
        ),
        .target(
            name: "AgenticDaemonLib",
            dependencies: [
                "AgenticJobKit",
                .product(name: "CrashReporter", package: "plcrashreporter")
            ],
            path: "Sources/AgenticDaemonLib",
            linkerSettings: [.linkedLibrary("sqlite3")]
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
