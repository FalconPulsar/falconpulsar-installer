// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FalconPulsarInstaller",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FalconPulsarInstaller",
            path: "FalconPulsarInstaller",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
