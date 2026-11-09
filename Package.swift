// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nxtch",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Nxtch",
            path: "Sources/Nxtch",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
