// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TestingPackage",
    platforms: [.iOS(.v11),],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "TestingPackage",
            targets: ["TestingPackage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.4.4")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "TestingPackage",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "InternalExecutableTarget",
            dependencies: ["InternalRegularTarget"]
        ),
        .target(name: "InternalRegularTarget"),
        .testTarget(
            name: "TestingPackageTests",
            dependencies: ["InternalRegularTarget"]
        )
    ]
)
