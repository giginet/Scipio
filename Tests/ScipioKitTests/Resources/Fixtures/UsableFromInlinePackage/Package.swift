// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "UsableFromInlinePackage",
    products: [
        .library(
            name: "UsableFromInlinePackage",
            targets: ["UsableFromInlinePackage"]),
    ],
    targets: [
        .target(
            name: "ClangModule"
        ),
        .target(
            name: "UsableFromInlinePackage",
            dependencies: ["ClangModule"]
        ),
    ]
)
