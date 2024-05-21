# Learn the Cache System

Learn about Scipio cache system

## Overview

Scipio attempt to reuse valid artifacts to avoid unnecessary build.

This document explains about how to reuse build artifacts in Scipio.

## Version File

Scipio generates VersionFile to describe built framework details within building XCFrameworks.

VersionFile contains the following information:

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
    "buildConfiguration" : "debug",
    "enableLibraryEvolution" : false,
    "frameworkType" : "static",
    "isDebugSymbolsEmbedded" : true,
    "sdks" : [
      "iOS",
      "iOSSimulator",
      "watchOS",
      "watchOSSimulator"
    ]
  },
  "clangVersion" : "clang-1500.3.9.4",
  "pin" : {
    "revision" : "32e8d724467f8fe623624570367e3d50c5638e46",
    "version" : "1.5.2"
  },
  "scipioVersion" : "9456405b33f2a25c479ea31cad0ba3c0222d9e20",
  "targetName" : "Logging",
  "xcodeVersion" : {
    "xcodeBuildVersion" : "15F31d",
    "xcodeVersion" : "15.4"
  }
}
```

If the output directory already contains XCFramework and its VersionFile, Scipio compares an existing VersionFile and a current build context. 

Then these are matched. Scipio regards the binary as still valid so a building will be skipped.

```bash
$ scipio prepare MyDependencies --cache-policy default
🔁 Resolving Dependencies...
✅ Valid Logging.xcframework (48775a1aee3999b0225737fdc194e852fe1df222a6a8fa2c71e715399ac1b04a) is exists. Skip building.
❇️ Succeeded.
```

## Cache Policy

You can set a cache policy with `--cache-policy` option.

```bash
$ scipio prepare MyDependencies --cache-policy default
```

### Disabled

Never reuse already built frameworks. Overwrite existing frameworks everytime.

Use `disabled` for CLI.

### Project Cache(default)

VersionFiles are stored in output directories. Skip re-building when existing XCFramework is valid.

Use `project` for CLI.

### Local Disk Cache

Copy every build artifacts to `~/Library/Caches/Scipio`. If there are same binaries are exists in cache directory, skip re-building and copy them to the output directory.

Thanks to this strategy, you can reuse built artifacts in past.

Use `local` for CLI.

### Remote Disk Cache

Same as Local Disk Cache policy, but it uses remote disk cache instead of local.

It helps to share build artifacts among developers.

You can't use this cache policy with CLI. It's necessary to implement a build script to use a remote disk cache. 

See detail in <doc:build-pipeline>
