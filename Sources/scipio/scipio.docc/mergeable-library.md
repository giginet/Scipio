# Support Mergeable Library

Apple announced [Mergeable Library](https://developer.apple.com/documentation/xcode/configuring-your-project-to-use-mergeable-libraries) in WWDC23. Mergeable Library is the new framework type which can switch the linking style by the build configuration. It has the metadata to change the linking style on the link time.

Scipio supports `mergeable` framework type to distribute packages as mergeable libraries.

```shell
$ scipio create path/to/MyPackage --framework-type mergeable --enable-library-evolution
```

See details the official documentation and following WWDC session.

- [Configuring your project to use mergeable libraries | Apple Developer Documentation](https://developer.apple.com/documentation/xcode/configuring-your-project-to-use-mergeable-libraries)
- [Meet mergeable libraries - WWDC23 - Videos - Apple Developer](https://developer.apple.com/videos/play/wwdc2023/10268/)

In general, mergeable frameworks will be about 2x bigger binary size than the normal dynamic frameworks.

## How to check whether the built framework is mergeable or not

Mergeable frameworks have `LC_ATOM_INFO` load command in the binary. You can check it by `otool` command.

```shell
echo $(otool -l MyFramework.framework/MyFramework) | grep "LC_ATOM_INFO"
```

## Limitation

Some frameworks can't build as a dynamic framework by some reasons. They can't be distributed as mergeable libraries. Try `--framework-type static` instead.
