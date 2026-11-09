// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchMixer",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "NotchMixer",
            path: "Sources/NotchMixer",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
