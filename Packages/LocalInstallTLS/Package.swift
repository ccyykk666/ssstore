// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalInstallTLS",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LocalInstallTLS", targets: ["LocalInstallTLS"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.18.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.2.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.5.1"),
    ],
    targets: [
        .target(name: "LocalInstallTLS", dependencies: [
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .testTarget(name: "LocalInstallTLSTests", dependencies: [
            "LocalInstallTLS",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
    ]
)
