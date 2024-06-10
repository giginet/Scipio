// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

// extension SwiftSetting {
//     static let forwardTrailingClosures: Self = .enableUpcomingFeature("ForwardTrailingClosures")              // SE-0286, Swift 5.3,  SwiftPM 5.8+
//     static let existentialAny: Self = .enableUpcomingFeature("ExistentialAny")                                // SE-0335, Swift 5.6,  SwiftPM 5.8+
//     static let bareSlashRegexLiterals: Self = .enableUpcomingFeature("BareSlashRegexLiterals")                // SE-0354, Swift 5.7,  SwiftPM 5.8+
//     static let conciseMagicFile: Self = .enableUpcomingFeature("ConciseMagicFile")                            // SE-0274, Swift 5.8,  SwiftPM 5.8+
//     static let importObjcForwardDeclarations: Self = .enableUpcomingFeature("ImportObjcForwardDeclarations")  // SE-0384, Swift 5.9,  SwiftPM 5.9+
//     static let disableOutwardActorInference: Self = .enableUpcomingFeature("DisableOutwardActorInference")    // SE-0401, Swift 5.9,  SwiftPM 5.9+
//     static let deprecateApplicationMain: Self = .enableUpcomingFeature("DeprecateApplicationMain")            // SE-0383, Swift 5.10, SwiftPM 5.10+
//     static let isolatedDefaultValues: Self = .enableUpcomingFeature("IsolatedDefaultValues")                  // SE-0411, Swift 5.10, SwiftPM 5.10+
//     static let globalConcurrency: Self = .enableUpcomingFeature("GlobalConcurrency")                          // SE-0412, Swift 5.10, SwiftPM 5.10+
// }
//
// extension SwiftSetting: CaseIterable {
//     public static var allCases: [Self] {[.forwardTrailingClosures, .existentialAny, .bareSlashRegexLiterals, .conciseMagicFile, .importObjcForwardDeclarations, .disableOutwardActorInference, .deprecateApplicationMain, .isolatedDefaultValues, .globalConcurrency]}
// }
//
let swiftSettings: [SwiftSetting] = [
    // .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "Scipio",
    platforms: [
        .macOS(.v14),
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
                 branch: "release/6.0"),
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
                 from: "1.0.0"),
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
    ],
    swiftLanguageVersions: [.v5]
)

let isDevelopment = ProcessInfo.processInfo.environment["SCIPIO_DEVELOPMENT"] == "1"

// swift-docs is not needed for package users
if isDevelopment {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
        .package(url: "https://github.com/freddi-kit/ArtifactBundleGen.git", from: "0.0.6"),
    ]
}
