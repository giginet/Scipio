// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ResourcePackage",
    platforms: [
        .iOS(.v11)
    ],
    products: [
        .library(
            name: "ResourcePackage",
            targets: ["ResourcePackage"]),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "ResourcePackage",
            dependencies: [
            ],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
                .process("Resources/giginet.png"),
            ]
        )
    ]
)
