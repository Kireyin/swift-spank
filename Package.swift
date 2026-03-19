// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-spank",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/Kireyin/AppleSiliconAccelerometer.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "spank",
            dependencies: [
                .product(name: "AppleSiliconAccelerometer", package: "AppleSiliconAccelerometer"),
            ],
            path: "Sources/spank",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
