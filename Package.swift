// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tachyon",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tachyon", targets: ["Tachyon"]),
        // SwiftPM places products in one case-insensitive build directory on
        // macOS, so this intentionally cannot be named `tachyon`: it would
        // collide with `Tachyon`. `build.sh` keeps its distinct bundle name;
        // Homebrew exposes it on PATH as the user-facing `tachyon` command.
        .executable(name: "TachyonCLI", targets: ["TachyonCommand"])
    ],
    targets: [
        .target(
            name: "TachyonIPC",
            path: "Sources/TachyonIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Tachyon",
            dependencies: ["TachyonIPC"],
            path: "Sources/Tachyon",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "TachyonCLI",
            dependencies: ["TachyonIPC"],
            path: "Sources/TachyonCLI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "TachyonCommand",
            dependencies: ["TachyonCLI"],
            path: "Sources/TachyonCommand",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TachyonTests",
            dependencies: ["Tachyon", "TachyonCLI", "TachyonIPC"],
            path: "Tests/TachyonTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
