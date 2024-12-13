// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AsRemotePackage",
    products: [
        .library(
            name: "Foo",
            targets: ["Foo"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/giginet/scipio-testing.git", exact: "3.0.0"),
    ],
    targets: [
        .target(
            name: "Foo",
            dependencies: [
                .product(name: "ScipioTesting", package: "scipio-testing"),
            ]
        ),
    ]
)
