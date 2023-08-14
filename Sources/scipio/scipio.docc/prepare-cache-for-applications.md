# Prepare all dependencies for your application

Use `prepare` mode to generate required frameworks for a project

## Concept

The concept of Scipio, all dependencies wanted to be used in your application should be defined in one Package manifest.

`prepare` command is to build all dependencies as XCFrameworks in the manifest.

## Practical Usage

Let's see how to use scipio in `prepare` mode.

### 1. Create a new Swift Package to describe dependencies

First, create a new Swift Package to describe required dependencies.

Generally, it's recommended to make this in the same directory as your application's Xcode project.

```bash
$ mkdir MyAppDependencies
$ cd MyAppDependencies
$ swift package init
```

### 2. Edit `Package.swift` to describe your application's dependencies

Next, edit `Package.swift`.

```swift
// swift-tools-version: 5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MyAppDependencies",
    platforms: [
        // Specify platforms to build
        .iOS(.v14),
    ],
    products: [],
    dependencies: [
        // Add dependencies
        .package(url: "https://github.com/onevcat/APNGKit.git", exact: "2.2.1"),
    ],
    targets: [
        .target(
            name: "MyAppDependency",
            dependencies: [
                // List all dependencies to build
                .product(name: "APNGKit", package: "APNGKit"),
            ]),
    ]
)

```

You have to depend on all wanted products on the first target.

Declare all targets as a dependencies of a first target.

`platforms` must be specified. Scipio decides which SDKs to build based on this.

### 3. Run `prepare` command

Finally, run `prepare` command.

```bash
$ scipio prepare path/to/MyAppDependencies
> 🔁 Resolving Dependencies...
> 🗑️ Cleaning MyAppDependencies...
> 📦 Building APNGKit for iOS
> 🚀 Combining into XCFramework...
> 📦 Building Delegate for iOS
> 🚀 Combining into XCFramework...
> ❇️ Succeeded.
```

All XCFrameworks are generated into `MyAppDependencies/XCFramework` by default.

#### Options

`prepare` command has some options. These are available options.

|Flag|Description|Default|
|---------|------------|-----------|
|-\-configuration, -c|Build configuration for generated frameworks (debug / release)|release|
|-\-output, -o|Path indicates a XCFrameworks output directory|$PACKAGE_ROOT/XCFrameworks|
|-\-embed-debug-symbols|Whether embed debug symbols to frameworks or not|-|
|-\-static|Whether generated frameworks are Static Frameworks or not|-|
|-\-support-simulators|Whether also building for simulators of each SDKs or not|-|
|-\-cache-policy|How to reuse built frameworks|project|
|-\-enable-library-evolution|Whether to enable Library Evolution feature or not|-|


See `--help` for details.

