// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Frog",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Frog", targets: ["FrogApp"])],
    targets: [
        .target(name: "FrogCore", path: "native/FrogCore"),
        .executableTarget(name: "FrogApp", dependencies: ["FrogCore"], path: "native/FrogApp"),
        .testTarget(name: "FrogCoreTests", dependencies: ["FrogCore"], path: "native/Tests/FrogCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
