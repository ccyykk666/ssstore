// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeviceKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "IDevice", targets: ["IDevice"])],
    targets: [
        .binaryTarget(name: "IDevice", path: "IDevice.xcframework")
    ]
)
