// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ClangPackageWithUmbrellaDirectory",
    products: [
        .library(
            name: "MyTarget",
            targets: ["MyTarget"]
        ),
    ],
    targets: [
        .target(
            name: "MyTarget",
            publicHeadersPath: "include"
        )
    ]
)
