// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DaemonKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DaemonKit", targets: ["DaemonKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/plcrashreporter.git", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "DaemonKit",
            dependencies: [
                .product(name: "CrashReporter", package: "plcrashreporter")
            ],
            path: "Sources/DaemonKit"
        ),
        .testTarget(
            name: "DaemonKitTests",
            dependencies: ["DaemonKit"],
            path: "Tests/DaemonKitTests"
        )
    ]
)
