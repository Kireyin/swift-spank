// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-spank",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "spank",
            path: "Sources/spank",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
