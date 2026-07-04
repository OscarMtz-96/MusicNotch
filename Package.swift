// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MusicVisualizer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MusicVisualizer", targets: ["MusicVisualizer"]),
        .executable(name: "MusicVisualizerSelfCheck", targets: ["MusicVisualizerSelfCheck"])
    ],
    dependencies: [
        .package(url: "https://github.com/ejbills/mediaremote-adapter.git", revision: "cf30c4f1af29b5829d859f088f8dbdf12611a046")
    ],
    targets: [
        .target(name: "MusicVisualizerCore"),
        .executableTarget(
            name: "MusicVisualizer",
            dependencies: [
                "MusicVisualizerCore",
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter")
            ]
        ),
        .executableTarget(
            name: "MusicVisualizerSelfCheck",
            dependencies: ["MusicVisualizerCore"]
        )
    ]
)
