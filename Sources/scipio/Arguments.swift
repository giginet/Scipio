import Foundation
import ArgumentParser
import ScipioKit

extension URL: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(fileURLWithPath: argument)
    }
}

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

extension FrameworkType: ExpressibleByArgument { }
