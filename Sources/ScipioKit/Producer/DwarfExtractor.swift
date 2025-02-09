import Foundation
import PackageGraph
import Basics

struct DwarfExtractor<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    typealias Arch = String

    func dwarfPath(for target: ScipioResolvedModule, dSYMPath: TSCAbsolutePath) -> TSCAbsolutePath {
        dSYMPath.appending(components: "Contents", "Resources", "DWARF", target.name)
    }

    func dump(dwarfPath: TSCAbsolutePath) async throws -> [Arch: UUID] {
        let result = try await executor.execute("/usr/bin/xcrun", "dwarfdump", "--uuid", dwarfPath.pathString)

        let output = try result.unwrapOutput()

        return parseUUIDs(from: output)
    }

    private func parseUUIDs(from outputString: String) -> [Arch: UUID] {
        let regex = /([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12}) \((.+)\)/
        let results = outputString.matches(of: regex)

        return results.compactMap { result -> (String, UUID)? in
            guard let uuid = UUID(uuidString: String(result.output.1)) else { return nil }
            return (String(result.output.2), uuid)
        }
        .reduce(into: [:]) { dictionary, element in
            dictionary[element.0] = element.1
        }
    }
}

extension NSTextCheckingResult {
    func captured(by name: String, in originalText: String) -> String? {
        let range = range(withName: name)
        guard let swiftyRange = Range(range, in: originalText) else {
            return nil
        }
        return String(originalText[swiftyRange])
    }
}
