// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tachyon",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tachyon", targets: ["Tachyon"])
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
            dependencies: ["TachyonCLI", "TachyonIPC"],
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
