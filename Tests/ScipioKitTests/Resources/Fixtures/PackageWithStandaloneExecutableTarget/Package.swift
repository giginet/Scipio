// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PackageWithStandaloneExecutableTarget",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "MyLib",
            targets: ["MyLib"]
        ),
    ],
    targets: [
        // The executable produces no framework, so it is pruned from the build
        // graph; standalone because the xcbuild path cannot link an executable
        // product against the renamed module frameworks of its dependencies.
        .target(name: "MyLib", dependencies: ["HelperTool"]),
        .executableTarget(name: "HelperTool"),
    ]
)
