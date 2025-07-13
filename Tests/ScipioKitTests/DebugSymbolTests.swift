import Foundation
@testable import ScipioKit
import Testing

@Suite(.serialized)
struct DwarfExtractorTests {
    @Test(arguments: [
        (
            "UUID: 1B6B77A9-436C-3A55-884D-4E78EFCAC3ED (arm64) Delegate.framework.dSYM/Contents/Resources/DWARF/Delegate",
            [
                "arm64": "1B6B77A9-436C-3A55-884D-4E78EFCAC3ED"
            ]
        ),
        (
            """
            UUID: AD019F0E-1318-3F9F-92B6-9F95FBEBBE6F (armv7) MySample.app/MySample
            UUID: BB59C973-06AC-388F-8EC1-FA3701C9E264 (arm64) MySample.app/MySample
            """,
            [
                "armv7": "AD019F0E-1318-3F9F-92B6-9F95FBEBBE6F",
                "arm64": "BB59C973-06AC-388F-8EC1-FA3701C9E264",
            ]
        ),
    ])
    func extractDwarfDump(argument: (fixture: String, expectedUUIDs: [String: String])) async throws {
        let executor = StubbableExecutor { arguments in
            return StubbableExecutorResult(arguments: arguments, success: argument.fixture)
        }
        let extractor = DwarfExtractor(executor: executor)
        let dwarfPath = URL(fileURLWithPath: "/dev/null")
        let uuids = try await extractor.dump(dwarfPath: dwarfPath)

        let firstArguments = try #require(executor.calledArguments.first)
        #expect(firstArguments == ["/usr/bin/xcrun", "dwarfdump", "--uuid", dwarfPath.path])

        let expectedUUIDs = try argument.expectedUUIDs.mapValues {
            try #require(UUID(uuidString: $0))
        }
        #expect(uuids == expectedUUIDs)
    }
}
