// swift-tools-version: 6.0
// build.sh builds this and wraps the binary into Waffle.app.
import PackageDescription

let package = Package(
    name: "Waffle",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Speech recognition (Parakeet), voice detection and speaker diarization, all Core ML on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .executableTarget(
            name: "Waffle",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Waffle",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
