// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AsLocalPackage",
    products: [
        .library(
            name: "Foo",
            targets: ["Foo"]
        ),
    ],
    dependencies: [
        .package(path: "../../scipio-testing"),
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
