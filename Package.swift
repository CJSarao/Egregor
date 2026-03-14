// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Egregore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Egregore", targets: ["Egregore"]),
        .executable(name: "egregore-read", targets: ["EgregoreRead"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.16.0"),
    ],
    targets: [
        .executableTarget(
            name: "Egregore",
            dependencies: [
                .product(name: "WhisperKit", package: "whisperkit"),
            ],
            path: "Sources/Egregore"
        ),
        .executableTarget(
            name: "EgregoreRead",
            path: "Sources/EgregoreRead"
        ),
        .testTarget(
            name: "EgregoreTests",
            dependencies: ["Egregore"],
            path: "Tests/EgregoreTests"
        ),
    ]
)
