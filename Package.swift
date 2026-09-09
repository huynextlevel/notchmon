// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchMon",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The one dependency in the app. Everything else here is hand-rolled,
        // but an updater has to verify a signature, download safely and replace
        // the running binary atomically -- the failure mode is not a bad layout,
        // it is a channel for installing arbitrary software on someone's Mac.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6")
    ],
    targets: [
        // The wire between the app and the hook binary. A library rather than a
        // copied file: they are two processes and the one failure nobody would
        // notice is the two ends disagreeing about a message.
        .target(
            name: "NotchMonBridge",
            path: "Sources/NotchMonBridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // What an agent actually runs. Ships in the bundle beside tokscale.
        .executableTarget(
            name: "notchmon-hook",
            dependencies: ["NotchMonBridge"],
            path: "Sources/notchmon-hook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NotchMon",
            dependencies: [.product(name: "Sparkle", package: "Sparkle"), "NotchMonBridge"],
            path: "Sources/NotchMon",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // SwiftPM links the framework but never embeds it; Scripts/bundle.sh
            // copies it into Contents/Frameworks, and the executable needs an
            // rpath pointing there or it dies at launch with an image-not-found.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
            ])]
        ),
        .testTarget(
            name: "NotchMonTests",
            dependencies: ["NotchMon", "NotchMonBridge"],
            path: "Tests/NotchMonTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
