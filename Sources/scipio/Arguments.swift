import Foundation
import ArgumentParser
import ScipioKit

#if compiler(>=6.0)

extension URL: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(fileURLWithPath: argument)
    }
}

#else

extension URL: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(fileURLWithPath: argument)
    }
}

#endif

extension BuildConfiguration: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument.lowercased() {
        case "debug":
            self = .debug
        case "release":
            self = .release
        default:
            return nil
        }
    }
}
