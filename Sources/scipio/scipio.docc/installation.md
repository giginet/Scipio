# Install Scipio

Install Scipio at the first

## Use as CLI

Using with CLI, it's convenient to prepare your project dependencies or generate a single XCFramework from a Swift Package.

Currently, Scipio doesn't provide any binary distribution. You have to build it from source.

```bash
$ git clone git@github.com:giginet/Scipio.git
$ cd Scipio
$ swift run -c release scipio --help
```

To use CLI version of Scipio, first, see details in <doc:prepare-cache-for-applications>.

## Use as Package

If you want to implement your own build pipeline, you can use `ScipioKit` as a package dependency.

You can build own pipeline with Scipio. See details in <doc:build-pipeline>

