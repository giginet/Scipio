import Foundation
import Testing
@testable import ScipioKitCore

struct PinTests {
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    @Test(
        "A pin in the Package.resolved form decodes to a source control state and encodes back",
        arguments: [
            (
                ["revision": "0123456789abcdef"],
                Pin.State.sourceControl(revision: "0123456789abcdef")
            ),
            (
                ["revision": "0123456789abcdef", "version": "1.2.3"],
                Pin.State.sourceControl(revision: "0123456789abcdef", version: "1.2.3")
            ),
            (
                ["revision": "0123456789abcdef", "branch": "main"],
                Pin.State.sourceControl(revision: "0123456789abcdef", branch: "main")
            ),
        ]
    )
    func decodesAndReencodesPackageResolvedPin(
        packageResolvedState: [String: String],
        expectedState: Pin.State
    ) throws {
        let data = try makePinJSON(state: packageResolvedState)

        let pin = try jsonDecoder.decode(Pin.self, from: data)

        #expect(pin.identity == PackageFixture.identity)
        #expect(pin.kind == PackageFixture.kind)
        #expect(pin.location == PackageFixture.location)
        #expect(pin.state == expectedState)

        let object = try #require(
            try JSONSerialization.jsonObject(with: jsonEncoder.encode(pin)) as? [String: Any]
        )

        #expect(object["identity"] as? String == PackageFixture.identity)
        #expect(object["kind"] as? String == PackageFixture.kind)
        #expect(object["location"] as? String == PackageFixture.location)
        #expect(object["state"] as? [String: String] == packageResolvedState)
    }

    @Test(
        "A pin missing a required key fails to decode as a missing key",
        arguments: [
            (nil, "state"),
            (["version": "1.2.3"], "revision"),
        ] as [([String: String]?, String)]
    )
    func rejectsPinWithMissingRequiredKey(state: [String: String]?, missingKeyName: String) throws {
        let data = try makePinJSON(state: state)

        #expect {
            try jsonDecoder.decode(Pin.self, from: data)
        } throws: {
            ($0 as? DecodingError)?.isKeyNotFound(named: missingKeyName) == true
        }
    }

    @Test("A registry pin round-trips without a revision", arguments: [false, true])
    func registryPinWithoutRevision(explicitNullRevision: Bool) throws {
        let data = try jsonEncoder.encode(RegistryPinFixture(
            state: .init(version: "1.2.3", explicitNullRevision: explicitNullRevision)
        ))

        let pin = try jsonDecoder.decode(Pin.self, from: data)
        #expect(pin.state == .registry(identity: "example.library", version: "1.2.3"))
        #expect(pin.location.isEmpty)
        #expect(try jsonDecoder.decode(Pin.self, from: jsonEncoder.encode(pin)) == pin)
        let object = try #require(try JSONSerialization.jsonObject(with: jsonEncoder.encode(pin)) as? [String: Any])
        #expect(object["state"] as? [String: String] == ["version": "1.2.3"])
    }

    @Test("A registry pin requires a version")
    func registryPinMissingVersion() throws {
        let data = try jsonEncoder.encode(RegistryPinFixture(state: .init(version: nil)))
        #expect {
            try jsonDecoder.decode(Pin.self, from: data)
        } throws: {
            ($0 as? DecodingError)?.isKeyNotFound(named: "version") == true
        }
    }

    private func makePinJSON(state: [String: String]?) throws -> Data {
        var object: [String: Any] = [
            "identity": PackageFixture.identity,
            "kind": PackageFixture.kind,
            "location": PackageFixture.location,
        ]
        object["state"] = state
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private enum PackageFixture {
    static let identity = "example"
    static let kind = "remoteSourceControl"
    static let location = "https://github.com/example/example.git"
}

private extension DecodingError {
    func isKeyNotFound(named name: String) -> Bool {
        guard case .keyNotFound(let key, _) = self else {
            return false
        }
        return key.stringValue == name
    }
}

private struct RegistryPinFixture: Encodable {
    let identity = "example.library"
    let kind = "registry"
    let location = ""
    let state: State

    struct State: Encodable {
        var version: String?
        var explicitNullRevision = false

        private enum CodingKeys: String, CodingKey {
            case version, revision
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(version, forKey: .version)
            if explicitNullRevision {
                try container.encodeNil(forKey: .revision)
            }
        }
    }
}
