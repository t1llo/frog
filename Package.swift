// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Frog",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Frog", targets: ["FrogApp"]),
        .library(name: "FrogCore", targets: ["FrogCore"]),
        .library(name: "FrogUsage", targets: ["FrogUsage"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.12.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.1"),
        // Newer collections emits borrowing runtime symbols unavailable on macOS 14–26.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1")
    ],
    targets: [
        .target(name: "FrogUsage", path: "native/FrogUsage"),
        .target(name: "FrogCore", path: "native/FrogCore"),
        .executableTarget(name: "FrogApp", dependencies: ["FrogCore", "FrogUsage", .product(name: "Sparkle", package: "Sparkle"), .product(name: "WhisperKit", package: "WhisperKit"), .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "Hub", package: "swift-transformers")], path: "native/FrogApp", resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "FrogCoreTests", dependencies: ["FrogCore"], path: "native/Tests/FrogCoreTests"),
        .testTarget(name: "FrogAppTests", dependencies: ["FrogApp", "FrogCore", "FrogUsage"], path: "native/Tests/FrogAppTests"),
        .testTarget(name: "FrogUsageTests", dependencies: ["FrogUsage"], path: "native/Tests/FrogUsageTests")
    ],
    swiftLanguageModes: [.v5]
)
