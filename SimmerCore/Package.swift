// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimmerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SimmerCore", targets: ["SimmerCore"]),
        .executable(name: "simmerctl", targets: ["simmerctl"]),
    ],
    targets: [
        .target(name: "SimmerCore"),
        .executableTarget(name: "simmerctl", dependencies: ["SimmerCore"]),
        .testTarget(name: "SimmerCoreTests", dependencies: ["SimmerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
