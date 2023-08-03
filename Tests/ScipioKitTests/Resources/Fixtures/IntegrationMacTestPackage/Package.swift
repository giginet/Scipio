// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "IntegrationMacTestPackage",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "IntegrationMacTestPackage",
            targets: ["IntegrationMacTestPackage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.24.0")
    ],
    targets: [
        .target(
            name: "IntegrationMacTestPackage",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
    ]
)
