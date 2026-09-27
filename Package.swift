// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "EchoModules",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "EchoCore", targets: ["EchoCore"]),
        .library(name: "EchoCapture", targets: ["EchoCapture"]),
        .library(name: "EchoIntelligence", targets: ["EchoIntelligence"]),
        .library(name: "EchoRuntime", targets: ["EchoRuntime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.0"),
    ],
    targets: [
        .target(name: "EchoCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "EchoAudioRing", publicHeadersPath: "include"),
        .target(name: "EchoCapture", dependencies: ["EchoCore", "EchoAudioRing"]),
        .target(name: "EchoIntelligence", dependencies: [
            "EchoCore", .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "EchoRuntime", dependencies: ["EchoCore", "EchoIntelligence"]),
        .testTarget(name: "EchoCoreTests", dependencies: ["EchoCore"]),
        .testTarget(name: "EchoCaptureTests", dependencies: ["EchoCapture"]),
        .testTarget(name: "EchoIntelligenceTests", dependencies: ["EchoIntelligence"]),
        .testTarget(name: "EchoRuntimeTests", dependencies: ["EchoRuntime"]),
    ],
    swiftLanguageModes: [.v5]
)
