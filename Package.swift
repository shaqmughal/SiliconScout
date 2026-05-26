// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SiliconScout",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "siliconscout",
            path: "Sources/siliconscout"
        )
    ]
)
