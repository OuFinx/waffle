// swift-tools-version: 6.0
// build.sh builds this and wraps the binary into Waffle.app. Parakeet comes from Homebrew (`brew install whisper-cpp`).
import PackageDescription

let brew = "/opt/homebrew"  // Apple Silicon Homebrew

let package = Package(
    name: "Waffle",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Speaker diarization ("who spoke when") on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        .systemLibrary(name: "CParakeet", path: "Sources/CParakeet"),
        .executableTarget(
            name: "Waffle",
            dependencies: ["CParakeet", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Waffle",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Xcc", "-I\(brew)/include"])],
            linkerSettings: [.unsafeFlags(["-L\(brew)/lib"])]
        ),
    ]
)
