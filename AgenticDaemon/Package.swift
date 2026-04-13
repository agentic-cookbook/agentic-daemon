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
            name: "AgenticXPCProtocol",
            path: "Sources/AgenticXPCProtocol"
        ),
        .target(
            name: "AgenticDaemonLib",
            dependencies: [
                "AgenticJobKit",
                "AgenticXPCProtocol",
                .product(name: "CrashReporter", package: "plcrashreporter")
            ],
            path: "Sources/AgenticDaemonLib"
        ),
        .executableTarget(
            name: "agentic-daemon",
            dependencies: ["AgenticDaemonLib"],
            path: "Sources/CLI"
        ),
        .target(
            name: "AgenticMenuBarLib",
            dependencies: ["AgenticXPCProtocol"],
            path: "Sources/AgenticMenuBarLib"
        ),
        .executableTarget(
            name: "AgenticMenuBar",
            dependencies: ["AgenticMenuBarLib"],
            path: "Sources/AgenticMenuBar"
        ),
        .testTarget(
            name: "AgenticDaemonTests",
            dependencies: ["AgenticDaemonLib"],
            path: "Tests",
            exclude: ["AgenticMenuBarTests"]
        ),
        .testTarget(
            name: "AgenticMenuBarTests",
            dependencies: ["AgenticMenuBarLib"],
            path: "Tests/AgenticMenuBarTests"
        )
    ]
)
