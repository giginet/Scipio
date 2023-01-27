// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BinaryPackage",
    platforms: [
        .iOS(.v11)
    ],
    products: [
        .library(name: "BinaryPackage",
                 targets: ["SomeBinary"])
    ],
    dependencies: [
    ],
    targets: [
        .binaryTarget(
            name: "SomeBinary",
            path: "SomeBinary.zip"
        )
    ]
)
