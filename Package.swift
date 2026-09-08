// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchMon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchMon",
            path: "Sources/NotchMon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NotchMonTests",
            dependencies: ["NotchMon"],
            path: "Tests/NotchMonTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
