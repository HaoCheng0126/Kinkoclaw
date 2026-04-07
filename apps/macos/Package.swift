// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "KinkoClaw",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "KinkoClaw", targets: ["KinkoClaw"]),
    ],
    targets: [
        .executableTarget(
            name: "KinkoClaw",
            path: "Sources/KinkoClaw",
            exclude: [
                "Resources/Info.plist",
            ],
            resources: [
                .copy("Resources/KinkoClaw.icns"),
                .copy("Resources/StageRuntime"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "KinkoClawTests",
            dependencies: [
                "KinkoClaw",
            ],
            path: "Tests/KinkoClawTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableExperimentalFeature("SwiftTesting"),
            ]),
    ])
