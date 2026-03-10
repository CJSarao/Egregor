// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Egregore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Egregore", targets: ["Egregore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.16.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", .upToNextMinor(from: "2.3.0")),
    ],
    targets: [
        .executableTarget(
            name: "Egregore",
            dependencies: [
                .product(name: "WhisperKit", package: "whisperkit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Egregore"
        ),
        .testTarget(
            name: "EgregoreTests",
            dependencies: ["Egregore"],
            path: "Tests/EgregoreTests"
        ),
    ]
)
