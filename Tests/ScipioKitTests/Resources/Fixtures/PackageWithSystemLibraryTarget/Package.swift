// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PackageWithSystemLibraryTarget",
    platforms: [.iOS(.v12)],
    products: [
        .library(
            name: "MainLib",
            targets: ["MainLib"]
        ),
    ],
    targets: [
        .target(name: "CoreLib"),
        .systemLibrary(name: "SysShim"),
        .target(
            name: "MainLib",
            // The system-library header includes CoreLib's header, so importers carry both.
            dependencies: ["CoreLib", "SysShim"]
        ),
    ]
)
