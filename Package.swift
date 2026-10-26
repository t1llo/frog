// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Frog",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Frog", targets: ["FrogApp"]),
        // Shipped as Frog.app/Contents/Helpers/frog. Named apart from "Frog", which it would collide with on a case-insensitive disk.
        .executable(name: "frog-cli", targets: ["FrogCLI"]),
        .library(name: "FrogCore", targets: ["FrogCore"]),
        .library(name: "FrogUsage", targets: ["FrogUsage"]),
        .library(name: "FrogAgent", targets: ["FrogAgent"])
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
        .target(name: "FrogCore", path: "native/FrogCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        // The `frog` tool's wire format and socket, shared by the app and the tool.
        .target(name: "FrogAgent", path: "native/FrogAgent", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "FrogCLI", dependencies: ["FrogAgent"], path: "native/FrogCLI", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "FrogApp", dependencies: ["FrogCore", "FrogUsage", "FrogAgent", .product(name: "Sparkle", package: "Sparkle"), .product(name: "WhisperKit", package: "WhisperKit"), .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "Hub", package: "swift-transformers")], path: "native/FrogApp", resources: [.process("Resources")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // Helpers shared by the test targets; nothing in the app links it.
        .target(name: "FrogTestSupport", path: "native/Tests/FrogTestSupport"),
        .testTarget(name: "FrogCoreTests", dependencies: ["FrogCore"], path: "native/Tests/FrogCoreTests"),
        .testTarget(name: "FrogAppTests", dependencies: ["FrogApp", "FrogCore", "FrogUsage", "FrogAgent", "FrogTestSupport"], path: "native/Tests/FrogAppTests"),
        .testTarget(name: "FrogAgentTests", dependencies: ["FrogAgent"], path: "native/Tests/FrogAgentTests"),
        .testTarget(name: "FrogUsageTests", dependencies: ["FrogUsage", "FrogTestSupport"], path: "native/Tests/FrogUsageTests")
    ],
    swiftLanguageModes: [.v5]
)
