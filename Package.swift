// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FalaDictation",
    platforms: [.macOS(.v14), .iOS("18.0")],
    products: [.library(name: "FalaCore", targets: ["FalaCore"])],
    targets: [
        .target(name: "FalaCore"),
        .testTarget(name: "FalaCoreTests", dependencies: ["FalaCore"])
    ]
)
