// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Scipio",
    platforms: [
        .macOS(.v11),
    ],
    products: [
        .executable(name: "scipio",
                    targets: ["scipio"]),
        .library(
            name: "ScipioKit",
            targets: ["ScipioKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-package-manager.git",
                 branch: "release/5.6"),
    ],
    targets: [
        .executableTarget(name: "scipio",
                          dependencies: ["ScipioKit"]),
        .target(
            name: "ScipioKit",
            dependencies: []),
        .testTarget(
            name: "ScipioKitTests",
            dependencies: ["ScipioKit"]),
    ]
)
