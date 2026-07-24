// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

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
