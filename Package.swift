// swift-tools-version:5.9
import PackageDescription
import Foundation

let mtpEnabled = ProcessInfo.processInfo.environment["SHIFT_ENABLE_MTP"] == "1"

var shiftDependencies: [Target.Dependency] = []
var shiftTargets: [Target] = []
var shiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

if mtpEnabled {
    shiftTargets.append(
        .systemLibrary(
            name: "Clibmtp",
            pkgConfig: "libmtp",
            providers: [.brew(["libmtp"])]
        )
    )
    shiftTargets.append(
        .target(
            name: "ShiftMTPBridge",
            dependencies: ["Clibmtp"],
            path: "Sources/ShiftMTPBridge",
            publicHeadersPath: "include"
        )
    )
    shiftDependencies.append("ShiftMTPBridge")
    shiftSettings.append(.define("SHIFT_ENABLE_MTP"))
}

let package = Package(
    name: "Shift",
    platforms: [
        .macOS(.v13)
    ],
    targets: shiftTargets + [
        .executableTarget(
            name: "Shift",
            dependencies: shiftDependencies,
            path: "Sources/Shift",
            resources: [
                .copy("../../Resources/Fonts")
            ],
            swiftSettings: shiftSettings
        )
    ]
)
