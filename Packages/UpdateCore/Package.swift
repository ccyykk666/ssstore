// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "UpdateCore", targets: ["UpdateCore"])],
    targets: [
        .target(name: "UpdateCore"),
        .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"])
    ]
)
