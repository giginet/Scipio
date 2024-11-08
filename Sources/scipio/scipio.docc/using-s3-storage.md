# Use Amazon S3 as a Cache Storage

Use Amazon S3 as a remote cache storage

## Overview

This guide will show you how to use Amazon S3 as a cache storage for your application.

Currently, you can't use the S3 backend from scipio CLI.

First, you have to prepare a custom build script. See <doc:build-pipeline> for detail.

To use AWS S3, you have to configure a suitable permission for buckets before. We will not explain the settings in this document.

## Use S3Storage for a Cache Backend

Using S3, add [scipio-s3-storage](https://github.com/giginet/scipio-s3-storage) package to your build script.

This package provides `ScipioS3Storage` target, it has S3 backend for cache storage.

Here is a sample implementation.

```swift
import ScipioS3Storage

let config = AuthorizedConfiguration(
    bucket: "my-bucket",
    region: "ap-northeast-1",
    shouldPublishObject: true,
    accessKeyID: "MY_ACCESS_ID",
    secretAccessKey: "MY_SECRET"
)

let s3Storage = S3Storage(config: .authorized(config))
let runner = Runner(
    mode: .prepareDependencies,
    options: .init(
        baseBuildOptions: .init(
            buildConfiguration: .release,
            isSimulatorSupported: true
        ),
        cacheMode: .storage(s3Storage, [.consumer, .producer])
    )
)
```

## Configuration

You can configure cache storage by `S3StorageConfig` and `AuthorizedConfiguration`.

### Configuration Type

You can choose configuration type from `authorized` and `publicURL`.

#### authorized

`authorized` type is associated with `AuthorizedConfiguration` which requires the followings: 

- bucket
- region
- access key ID
- secret access key

Generally, cache producer (e.g. CI job) should use this type.

##### shouldPublishObject

If you set `AuthorizedConfiguration.shouldPublishObject` to `true`, caches will be published with public URLs when producing caches.

You have to set `true` when producing caches when non-authorized consumers use caches.

#### publicURL

`publicURL` type doesn't require any credentials.

In this type, cache system will fetch caches by public URLs.
It's useful that developers just using caches should use this mode.
