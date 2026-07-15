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
        // produced for the executable, so it must stay out of the build graph while
        // its own library dependencies stay in.
        .target(name: "MyLib", dependencies: ["HelperTool"]),
        .executableTarget(name: "HelperTool", dependencies: ["ToolSupport"]),
        .target(name: "ToolSupport"),
    ]
)
