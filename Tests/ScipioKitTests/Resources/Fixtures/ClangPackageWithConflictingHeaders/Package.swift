// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ClangPackageWithConflictingHeaders",
    platforms: [.iOS(.v12)],
    products: [
        .library(
            name: "Consumer",
            targets: ["Consumer"]
        ),
    ],
    targets: [
        .target(name: "LibA"),
        .target(name: "LibB"),
        .target(
            name: "Consumer",
            dependencies: ["LibA", "LibB"]
        ),
    ]
)
