// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CCDiary",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "CCDiary",
            path: "Sources/CCDiary",
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
