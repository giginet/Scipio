// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Scipio",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .library(
            name: "Scipio",
            targets: ["Scipio"]),
    ],
    dependencies: [
        .package(name: "SwiftPM", url: "https://github.com/apple/swift-package-manager.git", .branch("release/5.6")),
    ],
    targets: [
        .executableTarget(name: "scipio"),
        .target(
            name: "ScipioKit",
            dependencies: []),
        .testTarget(
            name: "ScipioKitTests",
            dependencies: ["Scipio"]),
    ]
)
