# Create XCFramework by the package

`create` command can create XCFramework by any Swift Package.

XCFrameworks can be generated from any Swift Package with the create command.

This command is useful when generating XCFrameworks from an existing Swift Package.

Unlike the `prepare` command, there is no need to prepare a new package manifest.

Let's see an example to generate XCFrameworks from [apple/swift-log](https://github.com/apple/swift-log)

```bash
$ swift create path/to/swift-log
🔁 Resolving Dependencies...
📦 Building Logging for iOS, iPhone Simulator
🚀 Combining into XCFramework...
❇️ Succeeded.
```

## Options

Basically, this command can take the same options as the `prepare` command. <doc:prepare-cache-for-applications#Options>

### Specify target platforms

In the create command, you can create an XCFramework that contains only arbitrary platforms with the `-platforms` option.

```bash
$ swift create --platforms iOS --platforms watchOS path/to/swift-log
```

This is because, unlike the prepare command, the existing Swift Package lists all supported platforms.
By default, it builds for all of them.
