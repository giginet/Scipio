// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PackageWithExecutableTargetDependency",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "MyLib",
            targets: ["MyLib"]
        ),
    ],
    targets: [
        // A library target may depend on an executable target; no framework can be
        // produced for the executable, so it is pruned from the build graph together
        // with the dependencies only it reaches.
        .target(name: "MyLib", dependencies: ["HelperTool"]),
        .executableTarget(name: "HelperTool", dependencies: ["ToolSupport"]),
        .target(name: "ToolSupport"),
    ]
)
