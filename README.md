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

#### Library Evolution support

Scipio disables to support [Library Evolution](https://www.swift.org/blog/library-evolution/) feature by default.

It means built frameworks can be used only from products built with the same Swift version.

The primary reason why is Library Evolution limitation. 
In fact, some packages can't build with enabling Library Evolution. (https://developer.apple.com/forums/thread/123253, https://github.com/apple/swift-collections/issues/94, https://github.com/apple/swift-nio/issues/1257)

If you want to distribute generated XCFrameworks, it's recommended to enable Library Evolution. Pass `--enable-library-evolution` flag if you need.
However, it means some packages can't be built.

#### Build cache

By default, Scipio checks whether re-building is required or not for existing XCFrameworks.

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
