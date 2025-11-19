// swift-tools-version: 6.0
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
        .library(
            name: "ScipioCacheStorage",
            targets: ["CacheStorage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git",
                 from: "1.5.2"),
        .package(url: "https://github.com/apple/swift-collections",
                 from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git",
                 from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-algorithms.git",
                 from: "1.0.0"),
        .package(url: "https://github.com/onevcat/Rainbow",
                 from: "4.0.1"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git",
                 from: "5.0.0"),
        .package(url: "https://github.com/giginet/PackageManifestKit",
                 from: "0.1.0"),
        .package(url: "https://github.com/mtj0928/swift-async-operations.git",
                 from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "scipio",
            dependencies: [
                .target(name: "ScipioKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "ScipioKit",
            dependencies: [
                .target(name: "PIFKit"),
                .target(name: "ScipioKitCore"),
                .target(name: "CacheStorage"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "PackageManifestKit", package: "PackageManifestKit"),
                .product(name: "AsyncOperations", package: "swift-async-operations"),
            ],
            exclude: [
                "SwiftPM/NOTICE.txt",
                "SwiftPM/LICENSE",
            ],
            plugins: [
                .plugin(name: "GenerateScipioVersion")
            ]
        ),
        .target(
            name: "PIFKit",
            dependencies: [
                .product(name: "SwiftyJSON", package: "SwiftyJSON"),
            ]
        ),
        .target(
            name: "CacheStorage",
            dependencies: [
                "ScipioKitCore"
            ]
        ),
        .target(
            name: "ScipioKitCore",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "PackageManifestKit", package: "PackageManifestKit")
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
            exclude: ["Resources/Fixtures/"]
        ),
        .testTarget(
            name: "PIFKitTests",
            dependencies: [
                .target(name: "PIFKit"),
            ],
            exclude: ["Fixtures/"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

let isDevelopment = ProcessInfo.processInfo.environment["SCIPIO_DEVELOPMENT"] == "1"

// swift-docs is not needed for package users
if isDevelopment {
    package.dependencies += [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.3.0"),
    ]
}
