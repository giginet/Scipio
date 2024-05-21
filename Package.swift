// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "Scipio",
    platforms: [
        .macOS(.v13),
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
                 revision: "swift-5.10-RELEASE"),
        .package(url: "https://github.com/apple/swift-log.git",
                 from: "1.5.2"),
        .package(url: "https://github.com/apple/swift-collections",
                 from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git",
                 from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-algorithms.git",
                 from: "1.0.0"),
        .package(url: "https://github.com/onevcat/Rainbow",
                 .upToNextMinor(from: "4.0.1")),
        .package(url: "https://github.com/giginet/scipio-cache-storage.git",
                 revision: "ec3467983ae14356ffcba0ecf4e5c76c3dd80532"),
    ],
    targets: [
        .executableTarget(
            name: "scipio",
            dependencies: [
                .target(name: "ScipioKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ScipioKit",
            dependencies: [
                .product(name: "SwiftPMDataModel-auto", package: "swift-package-manager"),
                .product(name: "XCBuildSupport", package: "swift-package-manager"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "ScipioStorage", package: "scipio-cache-storage"),
            ],
            swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "GenerateScipioVersion")
            ]
        ),
        .plugin(
            name: "GenerateScipioVersion",
            capability: .buildTool()
        ),
        .testTarget(
            name: "ScipioKitTests",
            dependencies: [
                .target(name: "ScipioKit"),
            ],
            exclude: ["Resources/Fixtures/"],
            resources: [.copy("Resources/Fixtures")],
            swiftSettings: swiftSettings
        ),
    ]
)

let isDevelopment = ProcessInfo.processInfo.environment["SCIPIO_DEVELOPMENT"] == "1"

// swift-docs is not needed for package users
if isDevelopment {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ]
}
