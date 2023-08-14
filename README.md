# Scipio

## Carthago delenda est

Scipio proposes a new workflow to integrate dependencies into your applications.

This product is highly inspired by [Carthage](https://github.com/Carthage/Carthage) and [swift-create-xcframework](https://github.com/unsignedapps/swift-create-xcframework).

## Abstract

SwiftPM is the best way to integrate dependencies into your app.
However, build artifacts built by Xcode are difficult to cache.

On the other hand, [XCFramework](https://developer.apple.com/videos/play/wwdc2019/416/) is a good way to keep binaries portable.

Scipio provides a new hybrid way to manage dependencies.

First, use SwiftPM to resolve dependencies and checkout repositories. After that, this tool converts each dependency into XCFramework.

## Usage

#### Prepare `Package.swift` to describe your application's dependencies

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

#### Run `prepare` command

```
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

#### Library Evolution support

Scipio disables to support [Library Evolution](https://www.swift.org/blog/library-evolution/) feature by default.

It means built frameworks can be used only from products built with the same Swift version.

The primary reason why is Library Evolution limitation. 
In fact, some packages can't build with enabling Library Evolution. (https://developer.apple.com/forums/thread/123253, https://github.com/apple/swift-collections/issues/94, https://github.com/apple/swift-nio/issues/1257)

If you want to distribute generated XCFrameworks, it's recommended to enable Library Evolution. Pass `--enable-library-evolution` flag if you need.
However, it means some packages can't be built.

## Build Cache System

By default, Scipio checks whether re-building is required or not for existing XCFrameworks.

```
$ swift run scipio prepare --cache-policy project path/to/MyAppDependencies
> 🔁 Resolving Dependencies...
> 🗑️ Cleaning MyAppDependency...
> ✅ Valid APNGKit.xcframework is exists. Skip building.
> ✅ Valid Delegate.xcframework is exists. Skip building.
> ❇️ Succeeded.
```

Scipio supports Project/Local Disk/Remote Disk cache backends.

Using a remote cache, share built XCFrameworks among developers.

See details for [Learn the Cache System].

### Create XCFramework from a single Swift Package

Scipio also can generate XCFrameworks from a specific Swift Package. This feature is similar to swift-create-xcframework.

```
$ scipio create path/to/MyPackage
> 🔁 Resolving Dependencies...
> 🗑️ Cleaning MyPackage...
> 📦 Building MyPackage for iOS
> 🚀 Combining into XCFramework...
> ❇️ Succeeded.
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

