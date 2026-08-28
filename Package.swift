// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tachyon",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Tachyon",
            path: "Sources/Tachyon",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
