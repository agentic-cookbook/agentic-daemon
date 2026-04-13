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
        .package(path: "../DaemonKit")
    ],
    targets: [
        .target(
            name: "AgenticJobKit",
            path: "Sources/AgenticJobKit"
        ),
        .target(
            name: "AgenticXPCProtocol",
            dependencies: ["DaemonKit"],
            path: "Sources/AgenticXPCProtocol"
        ),
        .target(
            name: "AgenticDaemonLib",
            dependencies: [
                "AgenticJobKit",
                "AgenticXPCProtocol",
                "DaemonKit"
            ],
            path: "Sources/AgenticDaemonLib",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "agentic-daemon",
            dependencies: ["AgenticDaemonLib"],
            path: "Sources/CLI"
        ),
        .target(
            name: "AgenticMenuBarLib",
            dependencies: ["AgenticXPCProtocol", "DaemonKit"],
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
