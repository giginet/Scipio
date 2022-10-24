import Foundation
import PackageGraph

struct DebugSymbol {
    var dSYMPath: URL
    var target: ResolvedTarget
    var sdk: SDK
    var buildConfiguration: BuildConfiguration

    var dwarfPath: URL {
        dSYMPath.appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("DWARF")
            .appendingPathComponent(target.name)
    }
}

struct DwarfExtractor<E: Executor> {
    private let executor: E

    init(executor: E = ProcessExecutor()) {
        self.executor = executor
    }

    typealias Arch = String
    func dump(dwarfPath: URL) async throws -> [Arch: UUID] {
        let result = try await executor.execute("/usr/bin/xcrun", "dwarfdump", "--uuid", dwarfPath.path)

        let output = try result.unwrapOutput()

        return parseUUIDs(from: output)
    }

    private func parseUUIDs(from outputString: String) -> [Arch: UUID] {
        // TODO Use modern Regex
        let regex = try! NSRegularExpression(
            pattern: "(?<uuid>[0-9A-F]{8}\\-[0-9A-F]{4}\\-[0-9A-F]{4}\\-[0-9A-F]{4}\\-[0-9A-F]{12})\\s\\((?<arch>.+)\\)"
        )
        return regex.matches(in: outputString, range: NSRange(location: 0, length: outputString.utf16.count)).compactMap { match -> (String, UUID)? in
            guard let uuidString = match.captured(by: "uuid", in: outputString), let uuid = UUID(uuidString: uuidString) else { return nil }
            guard let arch = match.captured(by: "arch", in: outputString) else { return nil }
            return (arch, uuid)
        }
        .reduce(into: [:]) { (dict, element: (String, UUID)) in dict[element.0] = element.1 }
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
