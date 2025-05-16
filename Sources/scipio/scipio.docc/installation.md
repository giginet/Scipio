# Install Scipio

Install Scipio at the first

## Use as CLI

Using with CLI, it's convenient to prepare your project dependencies or generate a single XCFramework from a Swift Package.

### Using nest (Recommended)

Scipio provides [Artifact bundle](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0305-swiftpm-binary-target-improvements.md#artifact-bundle). Using [nest](https://github.com/mtj0928/nest), you can install Scipio easily without building.

```bash
$ nest install giginet/Scipio
```

### Build from source

You can build Scipio from source.

```bash
$ git clone https://github.com/giginet/Scipio.git
$ cd Scipio
$ swift run -c release scipio --help
# Add reference .build/release/scipio to the PATH variable.
$ export PATH=/path/to/scipio:$PATH
```

To use CLI version of Scipio, first, see details in <doc:prepare-cache-for-applications>.

## Use as Package

If you want to implement your own build pipeline, you can use `ScipioKit` as a package dependency.

You can build own pipeline with Scipio. See details in <doc:build-pipeline>

