// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SiliconScout",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SiliconScoutCore", targets: ["SiliconScoutCore"]),
    ],
    targets: [
        .target(
            name: "SiliconScoutCore",
            path: "Sources/SiliconScoutCore"
        ),
        .executableTarget(
            name: "siliconscout",
            dependencies: ["SiliconScoutCore"],
            path: "Sources/siliconscout"
        ),
        .executableTarget(
            name: "SiliconScoutApp",
            dependencies: ["SiliconScoutCore"],
            path: "Sources/SiliconScoutApp"
        ),
        .testTarget(
            name: "SiliconScoutCoreTests",
            dependencies: ["SiliconScoutCore"],
            path: "Tests/SiliconScoutCoreTests"
        ),
    ]
)
