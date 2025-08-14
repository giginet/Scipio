// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DynamicFrameworkOtherLDFlagsTestPackage",
    platforms: [.iOS(.v18), .macOS(.v10_15)],
    products: [
        .library(name: "DynamicFrameworkOtherLDFlagsTestPackage", targets: ["DynamicFrameworkOtherLDFlagsTestPackage"])
    ],
    dependencies: [
        .package(name: "UsableFromInlinePackage", path: "../UsableFromInlinePackage")
    ],
    targets: [
        .target(
            name: "DynamicFrameworkOtherLDFlagsTestPackage",
            dependencies: [
                .product(name: "UsableFromInlinePackage", package: "UsableFromInlinePackage")
            ]),
    ]
)
