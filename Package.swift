// swift-tools-version: 6.3
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License.

import PackageDescription

let package = Package(
    name: "VAPView",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "VAPView",
            targets: ["VAPView"]
        )
    ],
    targets: [
        .target(
            name: "VAPView",
            path: "Sources/VAPView",
            resources: [
                .process("Shaders")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "VAPViewTests",
            dependencies: ["VAPView"],
            path: "Tests/VAPViewTests"
        )
    ]
)
