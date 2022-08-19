# Scipio

## Carthago delenda est

Scipio proposes a new workflow to integrate dependencies into your applications.

This product is highly inspired by [Carthage](https://github.com/Carthage/Carthage) and [swift-create-xcframework](https://github.com/unsignedapps/swift-create-xcframework).

This is developed in working time for [LINE corp](https://github.com/LINE).

## Abstract

SwiftPM is the best way to integrate dependencies into your app. 
However, build artifacts built by Xcode are difficult to cache.

On the other hand, [XCFramework](https://developer.apple.com/videos/play/wwdc2019/416/) is a good way to keep binaries portable.

Scipio provides a new hybrid way to manage dependencies.

First, use SwiftPM to resolve dependencies and checkout repositories. After that, this tool converts each dependency into XCFramework.

## Usage

### Prepare all dependencies for your application.

#### 1. Create a new Swift Package to describe dependencies

```
$ cd path/to/MyAppDependencies
$ swift package init
```

#### 2. Edit `Package.swift` to describe your application's dependencies

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
                .productItem(name: "APNGKit", package: "APNGKit"),
            ]),
    ]
)

```

#### 3. Run `prepare` command

```
$ scipio prepare path/to/MyAppDependencies
> 🔁 Resolving Dependencies...
> 🗑️ Cleanin gMyAppEDependencies...
> 📦 Building APNGKit for iOS
> 🚀 Combining into XCFramework...
> 📦 Building Delegate for iOS
> 🚀 Combining into XCFramework...
> ❇️ Succeeded.
```

All XCFrameworks are generated into `MyAppDependencies/XCFramework` in default.

#### Options

|Flag|Description|Default|
|---------|------------|-----------|
|-\-configuration, -c|Build configuration for generated frameworks (debug / release)|release|
|-\-output, -o|Path indicates a XCFrameworks output directory|$PACKAGE_ROOT/XCFramework|
|-\-embed-debug-symbols|Whether embed debug symbols to frameworks or not|-|
|-\-support-simulators|Whether also building for simulators of each SDKs or not|-|
|-\-enable-cache|Whether skip building already built frameworks or not|-|


See `--help` for details.

#### Build cache

With `--enable-cache` option, Scipio checks whether re-building is required or not for existing XCFrameworks.

```
$ swift run scipio prepare --enable-cache path/to/MyAppDependencies
> 🔁 Resolving Dependencies...
> 🗑️ Cleaning LINEDependency...
> ✅ Valid APNGKit.xcframework is exists. Skip building.
> ✅ Valid Delegate.xcframework is exists. Skip building.
> ❇️ Succeeded.
```

Scipio creates **VersionFile**($OUTPUT_DIR/.$FRAMEWORK_NAME.version) to describe built framework details with XCFrameworks.

`VersionFile` contains the following information:

- Revision
    - Revision of packages. If resolved versions are updated, they may change.
- Build Option
    - Build options built with.
- Compiler Version
    - Xcode or Swift compiler version.

If they are changed, Spicio regards them as a cache are invalid, and then it's re-built.

### Create XCFramework for single Swift Packages

Scipio also can generate XCFrameworks from a specific Swift Package. This feature is similar to swift-create-xcframework.

```
$ scipio create path/to/MyPackage
> 🔁 Resolving Dependencies...
> 🗑️  CleaningMyPackage...
> 📦 Building MyPackage for iOS
> 🚀 Combining into XCFramework...
> ❇️  Succeeded.
```

## Reliability

Scipio only builts with standard dependencies and Apple official tools to keep reliability.

### How to resolve dependencies

Just run `swift package resolve`.

### How to parse package manifests and generate Xcode projects

Scipio depends on [swift-package-manager](https://github.com/apple/swift-package-manager) as a library.

Parsing package manifests and generating Xcode project is provided from the package. So it will be maintained in the future.

### How to build XCFrameworks

Scipio only uses `xcodebuild` to build Frameworks and XCFrameworks.

## Why Scipio

Scipio names after a historical story about Carthage.
