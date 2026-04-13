// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FalconPulsarMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FalconPulsarMenuBar",
            path: "FalconPulsar",
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
