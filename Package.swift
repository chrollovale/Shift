// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shift",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Shift",
            path: "Sources/Shift",
            resources: [
                .copy("../../Resources/Fonts")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
