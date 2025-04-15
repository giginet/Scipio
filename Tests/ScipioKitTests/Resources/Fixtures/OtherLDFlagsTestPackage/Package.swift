// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OtherLDFlagsTestPackage",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "OtherLDFlagsTestPackage", targets: ["OtherLDFlagsTestPackage"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.2.0")
    ],
    targets: [
        .target(
            name: "OtherLDFlagsTestPackage",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics")
            ]),
    ]
)
