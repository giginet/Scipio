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
        .package(url: "https://github.com/giginet/scipio-testing.git", .upToNextMinor(from: "2.0.0")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "TestingPackage",
            dependencies: [
                .product(name: "ScipioTesting", package: "scipio-testing"),
            ]),
    ]
)
