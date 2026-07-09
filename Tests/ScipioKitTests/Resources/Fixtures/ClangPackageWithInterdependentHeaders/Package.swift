// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ClangPackageWithInterdependentHeaders",
    platforms: [.iOS(.v12)],
    products: [
        .library(
            name: "Feature",
            targets: ["Feature"]
        ),
    ],
    targets: [
        .target(name: "CoreLib"),
        .target(
            name: "Feature",
            dependencies: ["CoreLib"]
        ),
    ]
)
