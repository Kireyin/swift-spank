// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-spank",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "AppleSiliconAccelerometer",
            targets: ["AppleSiliconAccelerometer"]
        ),
    ],
    targets: [
        .target(
            name: "AppleSiliconAccelerometer",
            path: "Sources/AppleSiliconAccelerometer",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "spank",
            dependencies: ["AppleSiliconAccelerometer"],
            path: "Sources/spank",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
