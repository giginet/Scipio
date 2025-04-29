// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OtherLDFlagsTestPackage",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "OtherLDFlagsTestPackage", targets: ["OtherLDFlagsTestPackage"])
    ],
    dependencies: [
        .package(name: "UsableFromInlinePackage", path: "../UsableFromInlinePackage")
    ],
    targets: [
        .target(
            name: "OtherLDFlagsTestPackage",
            dependencies: [
                .product(name: "UsableFromInlinePackage", package: "UsableFromInlinePackage")
            ]),
    ]
)
