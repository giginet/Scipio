# Build Your Pipeline

Implement your build pipeline by Swift code to run a complex build task

## Overview

You can use CLI version of `scipio` for a simple task. 
However, you can't configure a complex settings with this.

We also provide `ScipioKit` to build your pipeline. You can configure your pipeline by Swift code.

## Benefits to Implement a Build Script by `ScipioKit`

CLI version has a limitation to configure build options.

Implementing your build script can custom build system like following:

- Pass additional build options
    - XCConfig
    - Other C/Linker/Swift flags
- Override build options per build targets
- Use remote cache storage
- Implement complex behavior or user interface

## Setup

### Create an Executable Package

First, create a new Swift package to implement your script in an executable.

```bash
$ mkdir my-build-tool
$ cd my-build-tool
$ swift package init --type executable
Creating executable package: my-build-tool
Creating Package.swift
Creating .gitignore
Creating Sources/
Creating Sources/main.swift
```

### Open Your Package with Xcode

Edit the package with Xcode to implement your build script.

```bash
$ xed .
```

Remove `Sources/main.swift` before you add the `@main` entry point below.

### Edit a Package Manifest

Edit `Package.swift` to integrate Scipio as a dependency.

```swift
// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "my-build-tool",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            url: "https://github.com/giginet/Scipio.git", 
            exact: "0.34.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "my-build-tool", 
            dependencies: [
                .product(name: "ScipioKit", package: "Scipio"),
            ],
            path: "Sources"
        ),
    ]
)
```

> Note: Use `exact` to keep the Scipio version fixed. Update this value when you select another release.

### Implement a Build Script

Implement a script like following in `Sources/EntryPoint.swift`.

```swift
import Foundation
import ScipioKit

@main
struct EntryPoint {
    private static let myPackageDirectory = URL(fileURLWithPath: "/path/to/MyPackage")

    static func main() async throws {
        let runner = Runner(
            mode: .prepareDependencies,
            options: .init(
                baseBuildOptions: .init(
                    buildConfiguration: .release,
                    isSimulatorSupported: true
                )
            )
        )

        try await runner.run(
            packageDirectory: myPackageDirectory,
            frameworkOutputDir: .default
        )
    }
}
```

`ScipioKit` provides a `Runner`. It provides an entry point to execute the build process.

You can pass some settings on the initializer. Most of settings are same with the CLI version.

See details for documents in ScipioKit. (In Progress)

### Run the Script

Run your build script to test it. 

Build on Xcode or execute a following command on a terminal.

```bash
$ swift run -c release my-build-tool
```

## Advanced Settings

As we mentioned, you can configure advanced build options in the code.

### Pass Custom Build Flags

You can pass custom build flags to the build process.

```swift
let runner = Runner(
    mode: .prepareDependencies,
    options: .init(
        baseBuildOptions: .init(
            extraFlags: .init(
                cFlags: ["-D", "DEBUG"],
                cxxFlags: [],
                swiftFlags: ["-warn-concurrency"],
                linkerFlags: []
            ),
            extraBuildParameters: [
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone"
            ],
            enableLibraryEvolution: false
        ),
        frameworkCachePolicies: [.project],
        overwrite: true,
        verbose: true
    )
)
```

#### `extraFlags`

You can pass any C/C++/Swift/Linker flags to the build process.

#### `extraBuildParameters`

You can pass any Xcode build settings.

### Configure Build Options by Products

You can pass `buildOptionsMatrix` to override build settings for each product.

```swift
let runner = Runner(
    mode: .prepareDependencies,
    options: .init(
        baseBuildOptions: .init(
            buildConfiguration: .release,
            platforms: .specific([.iOS]),
            isSimulatorSupported: true,
            frameworkType: .static
        ),
        buildOptionsMatrix: [
            "MyResourceFramework": .init(
                frameworkType: .dynamic
            ),
            "MyTestingFramework": .init(
                buildConfiguration: .debug
            ),
            "MyWatchFramework": .init(
                platforms: .specific([.iOS, .watchOS])
            )
        ]
    )
)
```

This matrix can override build options of the specific targets to base build options.

Of-course, you are also pass `extraFlags` or `extraBuildParameters` per product.

#### Passing custom modulemap

Scipio attempt to generate modulemap automatically distributed in the XCFramework. However, if you want to custom modulemap, you can pass `frameworkModuleMapGenerationPolicy` to the build options. In general, this option should be used `buildOptionsMatrix`.

```swift
buildOptionsMatrix: [
    "MyResourceFramework": .init(
        frameworkModuleMapGenerationPolicy: .custom(URL(filePath: "path/to/module.modulemap"))
    ),
]

```

### Use Custom Cache Storage

In CLI version of Scipio, you can only use Project cache or Local disk cache as a cache storage backend.

Otherwise, on your build script, you can use remote cache storage or your custom storage.

```swift
import ScipioS3Storage

let s3Storage: some FrameworkCacheStorage = ScipioS3Storage.S3Storage(config: ...)
let runner = Runner(
    mode: .prepareDependencies,
    options: .init(
        baseBuildOptions: .init(
            buildConfiguration: .release,
            isSimulatorSupported: true
        ),
        frameworkCachePolicies: [
            .init(storage: s3Storage, actors: [.consumer]),
        ]
    )
)
```


Scipio provides `ScipioS3Storage` to use [Amazon S3](https://aws.amazon.com/jp/s3/) as a cache storage.

See details in <doc:using-s3-storage>

You can also implement your custom cache storage by implementing `FrameworkCacheStorage` protocol.

#### Cache Actor

There are two cache actors `consumer` and `producer`.

You can specify it by `Runner.Options.FrameworkCachePolicy.actors`.

`consumer` is an actor who can fetch cache from the cache storage.

`producer` is an actor who attempt to save cache to the cache storage.

When build artifacts are built, then it try to save them.

### Use multiple cache policies at the same time

You can also use multiple cache policies, which accepts multiple cache storages with different sets of cache actors:

```swift
import ScipioS3Storage

let s3Storage: some FrameworkCacheStorage = ScipioS3Storage.S3Storage(config: ...)
let runner = Runner(
    mode: .prepareDependencies,
    options: .init(
        baseBuildOptions: .init(
            buildConfiguration: .release,
            isSimulatorSupported: true
        ),
        frameworkCachePolicies: [
            .init(storage: s3Storage, actors: [.consumer]),
            .localDisk,
        ]
    )
)
```

In this example, Scipio first tries `s3Storage`, then `.localDisk` for the remaining targets. It checks `.localDisk` again before each target build. After each completed build, it schedules a local cache write and can continue to the next target. See <doc:cache-system> for cache timing, staging, and cleanup behavior.
 
