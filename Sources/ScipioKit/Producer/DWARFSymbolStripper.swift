import Foundation

/// Strip debug symbols from a binary.
struct DWARFSymbolStripper {
    private let executor: any Executor
    
    init(executor: some Executor) {
        self.executor = executor
    }
    
    func stripDebugSymbol(_ binaryPath: URL) async throws {
        try await executor.execute(
            "/usr/bin/xcrun",
            "strip",
            "-S",
            binaryPath.path(percentEncoded: false)
        )
    }
}
