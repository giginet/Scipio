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
                 revision: "4582d479ff0684e81d64897949c4d8d69187ec35"),
        .package(url: "https://github.com/apple/swift-log.git",
                 .upToNextMinor(from: "1.4.2")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", 
                 from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-algorithms.git", 
                 from: "1.0.0"),
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
                .product(name: "Algorithms", package: "swift-algorithms"),
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
