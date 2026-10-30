// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MumbleKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MumbleCore", targets: ["MumbleCore"]),
        .library(name: "MumbleASR", targets: ["MumbleASR"]),
        .library(name: "MumbleStore", targets: ["MumbleStore"]),
        .library(name: "MumbleSummary", targets: ["MumbleSummary"]),
        .executable(name: "mumble-eval", targets: ["MumbleEval"]),
    ],
    dependencies: [
        // Pinned exactly: FluidAudio moves fast and its API changes between minors.
        // Traits: keep inverse text normalization and diarization (meeting notes), drop TTS to stay small.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.0",
            traits: ["NemoTextProcessing", "Diarizer"]
        ),
        // SQLite for meeting notes: full-text search, migrations, observation.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
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
        .target(
            name: "MumbleStore",
            dependencies: ["MumbleCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "MumbleSummary", dependencies: ["MumbleCore"]),
        .executableTarget(
            name: "MumbleEval",
            dependencies: ["MumbleCore", "MumbleASR"]
        ),
        .testTarget(name: "MumbleCoreTests", dependencies: ["MumbleCore"]),
        .testTarget(name: "MumbleStoreTests", dependencies: ["MumbleStore", "MumbleCore"]),
        .testTarget(name: "MumbleSummaryTests", dependencies: ["MumbleSummary", "MumbleCore"]),
        .testTarget(name: "MumbleASRTests", dependencies: ["MumbleASR", "MumbleCore"]),
    ]
)
