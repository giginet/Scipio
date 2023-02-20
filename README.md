# Scipio

**⚠️ This project is currently under development. Please moment until a stable release. Of-course, feedbacks and pull requests are welcome.**

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
                .product(name: "APNGKit", package: "APNGKit"),
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
|-\-output, -o|Path indicates a XCFrameworks output directory|$PACKAGE_ROOT/XCFrameworks|
|-\-embed-debug-symbols|Whether embed debug symbols to frameworks or not|-|
|-\-static|Whether generated frameworks are Static Frameworks or not|-|
|-\-support-simulators|Whether also building for simulators of each SDKs or not|-|
|-\-cache-policy|How to reuse built frameworks|project|
|-\-disable-library-evolution|Whether to enable Library Evolution feature or not|-|


See `--help` for details.

#### Library Evolution support

Scipio automatically enables [Library Evolution](https://www.swift.org/blog/library-evolution/) feature in default.

It means built frameworks always keep compatibility even if linked from products built in other Swift versions. (ABI stability)

However, as known, some packages doesn't support Library Evolution or there are issues to generate swiftinterface. (https://developer.apple.com/forums/thread/123253)

You can disable Library Evolution with `--disable-library-evolution` flag if you need.

#### Build cache

In default, Scipio checks whether re-building is required or not for existing XCFrameworks.

```
$ swift run scipio prepare --cache-policy project path/to/MyAppDependencies
> 🔁 Resolving Dependencies...
> 🗑️ Cleaning MyAppDependency...
> ✅ Valid APNGKit.xcframework is exists. Skip building.
> ✅ Valid Delegate.xcframework is exists. Skip building.
> ❇️ Succeeded.
```

Scipio generates **VersionFile** to describe built framework details within building XCFrameworks.

`VersionFile` contains the following information:

- Revision
    - Revision of packages. If resolved versions are updated, they may change.
- Build Options
    - Build options built with.
- Compiler Version
    - Xcode or Swift compiler version.

They are stored on `$OUTPUT_DIR/.$FRAMEWORK_NAME.version` as a JSON file.

```json
{
  "buildOptions" : {
    "buildConfiguration" : "release",
    "isDebugSymbolsEmbedded" : false,
    "frameworkType" : "dynamic",
    "sdks" : [
      "iOS"
    ],
    "isSimulatorSupported" : false
  },
  "targetName" : "APNGKit",
  "clangVersion" : "clang-1400.0.29.102",
  "pin" : {
    "version" : "2.2.1",
    "revision" : "f1807697d455b258cae7522b939372b4652437c1"
  }
}
```

If they are changed, Spicio regards them as a cache are invalid, and then it's re-built.

#### Cache Policy

You can specify cache behavior with `--cache-policy` option. Default value is `project`.

##### disabled

Never reuse already built frameworks. Overwrite existing frameworks everytime.

##### project(default)

VersionFiles are stored in output directories. Skip re-building when existing XCFramework is valid.

##### local

Copy every build artifacts to `~/Library/Caches`. If there are same binaries are exists in cache directory, skip re-building and copy them to the output directory.

Thanks to this strategy, you can reuse built artifacts in past.

### Create XCFramework for single Swift Packages

Scipio also can generate XCFrameworks from a specific Swift Package. This feature is similar to swift-create-xcframework.

```
$ scipio create path/to/MyPackage
> 🔁 Resolving Dependencies...
> 🗑️ CleaningMyPackage...
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
