// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrafficMonitor",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "TrafficMonitor", targets: ["TrafficMonitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "TrafficMonitor",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TrafficMonitorTests",
            dependencies: ["TrafficMonitor"]
        ),
    ]
)
