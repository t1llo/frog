// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Frog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Frog", targets: ["FrogApp"]),
        .library(name: "FrogCore", targets: ["FrogCore"])
    ],
    targets: [
        .target(name: "FrogCore", path: "native/FrogCore"),
        .executableTarget(name: "FrogApp", dependencies: ["FrogCore"], path: "native/FrogApp"),
        .testTarget(name: "FrogCoreTests", dependencies: ["FrogCore"], path: "native/Tests/FrogCoreTests"),
        .testTarget(name: "FrogAppTests", dependencies: ["FrogApp", "FrogCore"], path: "native/Tests/FrogAppTests")
    ],
    swiftLanguageModes: [.v5]
)
