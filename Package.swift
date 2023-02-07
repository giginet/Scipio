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
        // https://github.com/apple/swift-package-manager/pull/5748
        .package(url: "https://github.com/apple/swift-package-manager.git",
                 revision: "3649109dd7c4e1c5ff90204bc93a0a7332711147"),
        .package(url: "https://github.com/apple/swift-log.git",
                 .upToNextMinor(from: "1.4.2")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", 
                 .upToNextMinor(from: "1.1.0")),
        .package(url: "https://github.com/onevcat/Rainbow",
                 .upToNextMinor(from: "4.0.1")),
    ],
    targets: [
        .executableTarget(name: "scipio",
                          dependencies: [
                            .target(name: "ScipioKit"),
                            .product(name: "ArgumentParser", package: "swift-argument-parser"),
                          ]),
        .target(
            name: "ScipioKit",
            dependencies: [
                .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
                .product(name: "XCBuildSupport", package: "swift-package-manager"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Rainbow", package: "Rainbow"),
            ]),
        .testTarget(
            name: "ScipioKitTests",
            dependencies: [
                .target(name: "ScipioKit"),
            ],
            exclude: ["Resources/Fixtures/"],
            resources: [.copy("Resources/Fixtures")]),
    ]
)
