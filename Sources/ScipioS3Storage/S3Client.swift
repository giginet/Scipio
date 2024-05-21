import Foundation
import SotoCore

protocol ObjectStorageClient: Sendable {
    init(storageConfig: S3StorageConfig) throws

    func putObject(_ data: Data, at key: String) async throws
    func isExistObject(at key: String) async throws -> Bool
    func fetchObject(at key: String) async throws -> Data
}

final class APIObjectStorageClient: ObjectStorageClient, Sendable {
    private let awsClient: AWSClient
    private let client: S3
    private let storageConfig: S3StorageConfig

    enum Error: LocalizedError {
        case emptyObject

        var errorDescription: String? {
            switch self {
            case .emptyObject:
                return "No object is found"
            }
        }
    }

    required init(storageConfig: S3StorageConfig) throws {
        switch storageConfig.authenticationMode {
        case .authorized(let accessKeyID, let secretAccessKey):
            awsClient = AWSClient(
                credentialProvider:
                    .static(accessKeyId: accessKeyID, secretAccessKey: secretAccessKey),
                httpClientProvider: .createNew
            )
            client = S3(
                client: awsClient,
                region: .init(awsRegionName: storageConfig.region),
                endpoint: storageConfig.endpoint.absoluteString
            )
        case .usePublicURL:
            fatalError("Invalid authorizationMode")
        }
        self.storageConfig = storageConfig
    }

    deinit {
        try? awsClient.syncShutdown()
    }

    func putObject(_ data: Data, at key: String) async throws {
        let acl: S3.ObjectCannedACL = storageConfig.shouldPublishObject ? .publicRead : .authenticatedRead
        let putObjectRequest = S3.PutObjectRequest(
            acl: acl,
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: storageConfig.bucket,
            key: key
        )
        _ = try await client.putObject(putObjectRequest)
    }

    func isExistObject(at key: String) async throws -> Bool {
        let headObjectRequest = S3.HeadObjectRequest(
            bucket: storageConfig.bucket,
            key: key
        )
        do {
            _ = try await client.headObject(headObjectRequest)
        } catch let error as S3ErrorType where error == .notFound {
            return false
        } catch {
            throw error
        }
        return true
    }

    func fetchObject(at key: String) async throws -> Data {
        let getObjectRequest = S3.GetObjectRequest(
            bucket: storageConfig.bucket,
            key: key
        )
        let response = try await client.getObject(getObjectRequest)
        guard let data = response.body?.asData() else {
            throw Error.emptyObject
        }
        return data
    }
}

struct PublicURLObjectStorageClient: ObjectStorageClient {
    private let storageConfig: S3StorageConfig
    private let httpClient: URLSession = .shared

    enum Error: LocalizedError {
        case putObjectIsNotSupported
        case unableToFetchObject(String)

        var errorDescription: String? {
            switch self {
            case .putObjectIsNotSupported:
                return "putObject requires authentication"
            case .unableToFetchObject(let key):
                return """
                Unable to fetch object for \"\(key)\".
                Object may not exist or not be public
                """
            }
        }
    }

    init(storageConfig: S3StorageConfig) throws {
        self.storageConfig = storageConfig
    }

    func putObject(_ data: Data, at key: String) async throws {
        throw Error.putObjectIsNotSupported
    }

    func isExistObject(at key: String) async throws -> Bool {
        let url = constructPublicURL(of: key)
        let request = {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            return request
        }()
        let (_, httpResponse) = try await httpClient.data(for: request)

        guard let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        return httpResponse.statusCode == 200
    }

    func fetchObject(at key: String) async throws -> Data {
        let url = constructPublicURL(of: key)
        let request = URLRequest(url: url)
        let (data, httpResponse) = try await httpClient.data(for: request)

        // Public URL returns 403 when object is not found
        guard let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw Error.unableToFetchObject(key)
        }
        return data
    }

    private func constructPublicURL(of key: String) -> URL {
        storageConfig.endpoint
            .appendingPathComponent(storageConfig.bucket)
            .appendingPathComponent(key)
    }
}
