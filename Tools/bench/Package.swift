// swift-tools-version: 6.0
// The meeting bench (see run.sh): the app's Logic.swift and Engine.swift on real meeting recordings.
import PackageDescription

let package = Package(
    name: "Bench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4")],
    targets: [.executableTarget(name: "Bench", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/Bench", swiftSettings: [.swiftLanguageMode(.v5)])]
)
