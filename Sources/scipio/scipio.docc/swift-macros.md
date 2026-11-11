# Use Swift Macros

Build and use compiler plugins alongside XCFrameworks.

## Overview

A Swift macro uses a macOS executable at compile time. Scipio prepares that executable as well as the XCFramework containing the macro declarations. The executable runs on the build host; it is not a framework and must not be embedded in an application.

## Declare the Macro Dependency

In the library package's `Package.swift`, declare the `.macro` target as a dependency of the library target that exposes or uses the macro. For example:

```swift
import PackageDescription
import CompilerPluginSupport

// Inside the package's targets:
.target(name: "ExampleLibrary", dependencies: ["ExamplePlugin"]),
.macro(name: "ExamplePlugin", dependencies: [/* implementation dependencies */]),
```

Specify the macro implementation dependencies required by the package. A `#externalMacro` declaration alone does not add a dependency to the package graph. Scipio discovers macro targets from the selected libraries' resolved dependencies, and the macro product must be reachable by SwiftPM when Scipio builds it. If the dependency is missing, add it to the package manifest before preparing the package.

Select the library product in your application's dependency package as described in <doc:prepare-cache-for-applications>. Then run:

```bash
scipio prepare MyAppDependencies
```

Scipio resolves the package graph, prepares the plugin for the host, and supplies it when compiling the dependent library. It prepares plugins even when the corresponding XCFramework is already cached.

## Locate the Artifacts

With the default output directory, the example produces:

```text
MyAppDependencies/
├── XCFrameworks/
│   └── ExampleLibrary.xcframework/
└── .build/scipio/MacroPlugins/
    ├── ExamplePlugin/
    │   ├── ExamplePlugin
    │   └── artifact.json
    └── plugins.json
```

`MacroPlugins` is always created inside the dependency package's Scipio workspace at `.build/scipio/MacroPlugins`, including when using a custom XCFramework output directory. `plugins.json` lists each plugin module, the executable path relative to `MacroPlugins`, and the library targets that depend on it. The per-plugin `artifact.json` records its files for validation. When a cache key is available and caching is enabled, `.build/scipio/MacroPlugins/.ExamplePlugin.version` records the plugin's build context.

For this example, `.build/scipio/MacroPlugins/plugins.json` contains:

```json
{
  "plugins": [
    {
      "executable": "ExamplePlugin/ExamplePlugin",
      "module": "ExamplePlugin",
      "targets": ["ExampleLibrary"]
    }
  ]
}
```

`executable` is relative to the directory containing `plugins.json`. `module` is the compiler plugin module name passed after `#`. `targets` lists dependency library targets that directly depend on that plugin; consuming application and test targets still need explicit loader flags. The manifest includes prepared plugins restored from cache and uses an empty `plugins` array when no plugins are required.

## Configure the Consumer

Link the XCFramework in your Xcode target. When compiling source that expands the macro, pass the plugin path and module name from `plugins.json` to the Swift compiler. For example, add the following to the consuming target's **Other Swift Flags**, replacing the path with the actual artifact location:

```text
$(inherited) -load-plugin-executable "$(SRCROOT)/MyAppDependencies/.build/scipio/MacroPlugins/ExamplePlugin/ExamplePlugin#ExamplePlugin"
```

Configure each target that expands the macro, including test targets. For multiple plugins, pass a separate `-load-plugin-executable` argument for each one. Xcode does not receive these flags automatically from the XCFramework. Keep the executable and its accompanying files on the build host.

## Caching

Project and local disk policies can cache macro artifacts. The plugin cache key includes the pinned host dependency graph, toolchain versions, host architecture, deployment target, and Scipio version. The plugin fingerprint also contributes to the cache keys of dependent frameworks.

If a macro or any dependency in its host graph has no pinned revision, such as an edited or local package, Scipio builds the plugin without a cache key and does not reuse cached dependent frameworks. With caching disabled, both plugins and frameworks are rebuilt.

Existing custom `FrameworkCacheStorage` implementations continue to cache frameworks. A storage can additionally implement `MacroPluginsCacheStorage` to cache macro artifacts. Existing versions of [scipio-s3-storage](https://github.com/giginet/scipio-s3-storage) do not support macro artifacts, so a consumer may have to build the plugin even when it restores the XCFramework from S3. To require publication through a macro-capable producer, set `Runner.Options.requireMacroArtifactStorage` to `true`; Scipio rejects unsupported producer policies and unpinned macro graphs.

## Current Limitations

- The host build uses SwiftPM's deprecated native build system.
- Artifacts are built for the current host architecture and toolchain; build separate compatible artifacts for other environments.
- The artifact assembly currently copies all bundles and dynamic libraries from SwiftPM's host products directory. Dependency-specific selection and portability of dynamically linked artifacts need further validation.
- Macro targets with duplicate module names are not supported.
