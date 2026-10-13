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
