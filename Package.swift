// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ccdiary",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ccdiary",
            path: "Sources/ccdiary",
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
