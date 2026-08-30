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
        ),
        .executable(
            name: "memory-monitor-fixture",
            targets: ["MemoryMonitorFixture"]
        ),
        .executable(
            name: "memory-monitor-app",
            targets: ["MemoryMonitorApp"]
        )
    ],
    targets: [
        .target(name: "MemoryMonitorCore"),
        .executableTarget(
            name: "MemoryMonitorProbe",
            dependencies: ["MemoryMonitorCore"]
        ),
        .executableTarget(
            name: "MemoryMonitorFixture",
            dependencies: ["MemoryMonitorCore"]
        ),
        .executableTarget(
            name: "MemoryMonitorApp",
            dependencies: ["MemoryMonitorCore"],
            linkerSettings: [
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "MemoryMonitorCoreTests",
            dependencies: ["MemoryMonitorCore"]
        ),
        .testTarget(
            name: "MemoryMonitorAppTests",
            dependencies: ["MemoryMonitorCore", "MemoryMonitorApp"]
        )
    ]
)
