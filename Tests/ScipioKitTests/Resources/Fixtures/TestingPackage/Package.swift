// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TestingPackage",
    platforms: [.iOS(.v11),],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "TestingPackage",
            targets: ["MyTarget"]
        ),
        .plugin(
            name: "MyPlugin",
            targets: ["MyPlugin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMinor(from: "1.4.4")),
    ],
    targets: [
        // Directly exported targets
        .target(
            name: "MyTarget",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .plugin(
            name: "MyPlugin",
            capability: .command(
                intent: .custom(
                    verb: "my-plugin-verb",
                    description: "my-plugin-description")),
            dependencies: ["ExecutableTarget"]
        ),
        // Transitevly exported targets
        .executableTarget(
            name: "ExecutableTarget",
            dependencies: ["MyTarget"]
        ),
        // Not exported (internal) targets
        .executableTarget(
            name: "InternalExecutableTarget",
            dependencies: ["InternalRegularTarget"]
        ),
        .target(name: "InternalRegularTarget"),
        .testTarget(
            name: "TestingPackageTests",
            dependencies: ["InternalRegularTarget"]
        )
    ]
)
