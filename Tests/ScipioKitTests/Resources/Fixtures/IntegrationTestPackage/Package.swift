// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IntegrationTestPackage",
    platforms: [.iOS(.v14), .macOS(.v13)],
    products: [
        .library(
            name: "IntegrationTestPackage",
            targets: ["IntegrationTestPackage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.3"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.2"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.4"),
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", from: "5.15.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.24.0")
    ],
    targets: [
        .target(
            name: "IntegrationTestPackage",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "SDWebImageMapKit", package: "SDWebImage"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]),
    ]
)
