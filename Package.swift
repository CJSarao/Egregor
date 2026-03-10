// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceShell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceShell", targets: ["VoiceShell"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.16.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", .upToNextMinor(from: "2.3.0")),
    ],
    targets: [
        .executableTarget(
            name: "VoiceShell",
            dependencies: [
                .product(name: "WhisperKit", package: "whisperkit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/VoiceShell"
        ),
        .testTarget(
            name: "VoiceShellTests",
            dependencies: ["VoiceShell"],
            path: "Tests/VoiceShellTests"
        ),
    ]
)
