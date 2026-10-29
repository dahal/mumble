// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MumbleKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MumbleCore", targets: ["MumbleCore"]),
        .library(name: "MumbleASR", targets: ["MumbleASR"]),
        .executable(name: "mumble-eval", targets: ["MumbleEval"]),
    ],
    dependencies: [
        // Pinned exactly: FluidAudio moves fast and its API changes between minors.
        // Traits: keep inverse text normalization, drop TTS and diarization to stay small.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.0",
            traits: ["NemoTextProcessing"]
        )
    ],
    targets: [
        // Pure logic with no model dependency, so its tests run in seconds.
        .target(name: "MumbleCore"),
        .target(
            name: "MumbleASR",
            dependencies: [
                "MumbleCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "MumbleEval",
            dependencies: ["MumbleCore", "MumbleASR"]
        ),
        .testTarget(name: "MumbleCoreTests", dependencies: ["MumbleCore"]),
        .testTarget(name: "MumbleASRTests", dependencies: ["MumbleASR", "MumbleCore"]),
    ]
)
