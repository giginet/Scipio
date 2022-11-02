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
                 revision: "swift-5.7-RELEASE"),
        .package(url: "https://github.com/apple/swift-log.git",
                 .upToNextMinor(from: "1.4.2")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", 
                 .upToNextMinor(from: "1.0.0")),
        .package(url: "https://github.com/onevcat/Rainbow",
                 .upToNextMinor(from: "4.0.1")),
        .package(url: "https://github.com/tuist/XcodeProj.git",
                 .upToNextMinor(from: "8.8.0")),
    ],
    targets: [
        .executableTarget(name: "scipio",
                          dependencies: [
                            .target(name: "ScipioKit"),
                            .productItem(name: "ArgumentParser", package: "swift-argument-parser"),
                          ]),
        .target(
            name: "ScipioKit",
            dependencies: [
                .productItem(name: "SwiftPM", package: "swift-package-manager"),
                .productItem(name: "Logging", package: "swift-log"),
                .productItem(name: "Rainbow", package: "Rainbow"),
                .productItem(name: "XcodeProj", package: "XcodeProj"),
            ]),
        .testTarget(
            name: "ScipioKitTests",
            dependencies: [
                .target(name: "ScipioKit"),
            ],
            exclude: ["Resources/Fixtures/"],
            resources: [.copy("Resources/Fixtures/TestingPackage/Package.swift")]),
    ]
)
