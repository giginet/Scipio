import Foundation
import ScipioKitCore

struct DwarfExtractor<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    typealias Arch = String

    func dwarfPath(for target: ResolvedModule, dSYMPath: URL) -> URL {
        dSYMPath.appending(components: "Contents", "Resources", "DWARF", target.name)
    }

    func dump(dwarfPath: URL) async throws -> [Arch: UUID] {
        let result = try await executor.execute("/usr/bin/xcrun", "dwarfdump", "--uuid", dwarfPath.path(percentEncoded: false))

        let output = try result.unwrapOutput()

        return parseUUIDs(from: output)
    }

    private func parseUUIDs(from outputString: String) -> [Arch: UUID] {
        let regex = /(?<uuid>[0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12}) \((?<arch>.+)\)/
        let results = outputString.matches(of: regex)

        return results.compactMap { result -> (arch: String, uuid: UUID)? in
            guard let uuid = UUID(uuidString: String(result.output.uuid)) else { return nil }
            return (String(result.output.arch), uuid)
        }
        .reduce(into: [:]) { dictionary, element in
            dictionary[element.arch] = element.uuid
        }
    }
}
