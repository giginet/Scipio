import Foundation
@testable import ScipioKit
import XCTest
import TSCBasic

final class DwarfExtractorTests: XCTestCase {
    let fixture = "UUID: 1B6B77A9-436C-3A55-884D-4E78EFCAC3ED (arm64) Delegate.framework.dSYM/Contents/Resources/DWARF/Delegate"

    func testExtractDwarfDump() async throws {
        let extractor = DwarfExtractor(executor: StubbableExecutor { arguments in
            return StubbableExecutorResult(arguments: arguments, success: self.fixture)
        })

        let uuids = try await extractor.dump(dwarfPath: AbsolutePath("/dev/null"))
        XCTAssertEqual(uuids.count, 1)
        XCTAssertEqual(uuids["arm64"], UUID(uuidString: "1B6B77A9-436C-3A55-884D-4E78EFCAC3ED"))
    }
}
