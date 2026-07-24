// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 FalconPulsar Contributors

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
