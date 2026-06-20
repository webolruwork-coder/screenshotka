// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Screenshotka",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Screenshotka",
            path: "Sources/Screenshotka",
            swiftSettings: [
                .unsafeFlags(["-F", "Vendor/Sparkle"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "Vendor/Sparkle",
                    "-framework", "Sparkle",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
