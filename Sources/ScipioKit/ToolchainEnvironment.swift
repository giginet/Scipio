import struct Basics.AbsolutePath
@_spi(SwiftPMInternal) import struct Basics.Environment

public typealias ToolchainEnvironment = [String: String]

extension ToolchainEnvironment {
    var developerDirPath: String? { self["DEVELOPER_DIR"] }
    var toolchainBinPath: Basics.AbsolutePath? {
        if let developerDirPath {
            return try? AbsolutePath(validating: developerDirPath)
                .appending(components: "Toolchains", "XcodeDefault.xctoolchain", "usr", "bin")
        }
        return nil
    }
}

extension ToolchainEnvironment {
    var asSwiftPMEnvironment: Environment { Environment(self) }
}
