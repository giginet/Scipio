# Using Amazon S3 as a cache storage

This guide will show you how to use Amazon S3 as a cache storage for your application.

Currently, you can't use the S3 backend from scipio CLI.

First, you have to prepare a custom build script. See <doc:build-pipeline> for detail.

## Use S3Storage for a cache backend

Scipio provides `ScipioS3Storage` target.

This package provides S3 backend for cache storage.

Here is a sample implementation.

```swift
import ScipioS3Storage

let config = S3StorageConfig(
    authenticationMode: authorized(
        accessKeyID: "MY_ACCESS_ID",
        secretAccessKey: "MY_SECRET",
        region: "ap-northeast-1",
        endpoint: awsEndpoint,
        shouldPublishObject: true
    )
)

let s3Storage = S3Storage(config: config)
let runner = Runner(
    mode: .prepareDependencies,
    options: .init(
        baseBuildOptions: .init(
            buildConfiguration: .release,
            isSimulatorSupported: true
        ),
        cacheStorage: .custom(s3Storage, [.consumer])
    )
)
```

## Configuration

You can configure cache storage by `S3StorageConfig`.

### Authentication mode

You can choose authentication mode from `authorized` and `usePublicURL`.

`authorized` mode requires access key ID and secret access key.

Generally, cache producer (e.g. CI job) should use this mode.

`usePubicURL` mode doesn't require any credentials.

In this mode, cache system will fetch caches by public URLs.
It's useful that developers just using caches should use this mode.

### `shouldPublishObject`

If you set `shouldPublishObject` to `true`, caches will be published with public URLs when producing caches.

You have to set `true` when producing caches when non-authorized consumers use caches.
