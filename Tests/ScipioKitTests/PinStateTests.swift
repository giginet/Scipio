import Foundation
import Testing
@testable import ScipioKitCore

struct PinStateTests {
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    private static let statesAndEncodedStates = [
        (
            Pin.State.sourceControl(revision: "0123456789abcdef"),
            ["kind": "sourceControl", "revision": "0123456789abcdef"]
        ),
        (
            Pin.State.sourceControl(revision: "0123456789abcdef", version: "1.2.3"),
            ["kind": "sourceControl", "revision": "0123456789abcdef", "version": "1.2.3"]
        ),
        (
            Pin.State.sourceControl(revision: "0123456789abcdef", branch: "main"),
            ["kind": "sourceControl", "revision": "0123456789abcdef", "branch": "main"]
        ),
    ]

    @Test(
        "State to JSON: a state encodes to an object with its kind, omitting absent keys",
        arguments: statesAndEncodedStates
    )
    func encodesStateToJSON(state: Pin.State, encodedState: [String: String]) throws {
        let data = try jsonEncoder.encode(state)

        #expect(try jsonDecoder.decode([String: String].self, from: data) == encodedState)
    }

    @Test(
        "JSON to state: an object with a kind decodes to a state",
        arguments: statesAndEncodedStates
    )
    func decodesStateFromJSON(state: Pin.State, encodedState: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: encodedState)

        #expect(try jsonDecoder.decode(Pin.State.self, from: data) == state)
    }

    @Test("A state with an unknown kind fails to decode as corrupted data")
    func rejectsUnknownKind() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["kind": "unknown", "revision": "0123456789abcdef"]
        )

        #expect {
            try jsonDecoder.decode(Pin.State.self, from: data)
        } throws: {
            ($0 as? DecodingError)?.isDataCorrupted() == true
        }
    }

    @Test(
        "A state missing a required key fails to decode as a missing key",
        arguments: [
            (["revision": "0123456789abcdef"], "kind"),
            (["kind": "sourceControl"], "revision"),
        ]
    )
    func rejectsStateWithMissingRequiredKey(json: [String: String], missingKeyName: String) throws {
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect {
            try jsonDecoder.decode(Pin.State.self, from: data)
        } throws: {
            ($0 as? DecodingError)?.isKeyNotFound(named: missingKeyName) == true
        }
    }

    @Test(
        "The version is nil unless the package is pinned to a version",
        arguments: statesAndEncodedStates
    )
    func versionOfState(state: Pin.State, encodedState: [String: String]) {
        #expect(state.version == encodedState["version"])
    }
}

private extension DecodingError {
    func isKeyNotFound(named name: String) -> Bool {
        guard case .keyNotFound(let key, _) = self else {
            return false
        }
        return key.stringValue == name
    }

    func isDataCorrupted() -> Bool {
        guard case .dataCorrupted = self else {
            return false
        }
        return true
    }
}
