// swift-tools-version: 6.0

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
            name: "ClangModuleForIOS"
        ),
        .target(
            name: "ClangModuleForMacOS"
        ),
        .target(
            name: "UsableFromInlinePackage",
            dependencies: [
                "ClangModule",
                .targetItem(name: "ClangModuleForIOS", condition: .when(platforms: [.iOS])),
                .targetItem(name: "ClangModuleForMacOS", condition: .when(platforms: [.macOS])),
            ]
        ),
    ]
)
