// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemoryMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MemoryMonitorCore",
            targets: ["MemoryMonitorCore"]
        ),
        .executable(
            name: "memory-monitor-probe",
            targets: ["MemoryMonitorProbe"]
        )
    ],
    targets: [
        .target(name: "MemoryMonitorCore"),
        .executableTarget(
            name: "MemoryMonitorProbe",
            dependencies: ["MemoryMonitorCore"]
        ),
        .testTarget(
            name: "MemoryMonitorCoreTests",
            dependencies: ["MemoryMonitorCore"]
        )
    ]
)
