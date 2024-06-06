import Foundation
import Logging
import Rainbow
import class Basics.ObservabilitySystem

let logger = Logger(label: "me.giginet.Scipio")

extension Logger.MetadataValue {
    static func color(_ color: NamedColor) -> Self {
        .stringConvertible(color.rawValue)
    }
}

extension Logger.Metadata {
    static func color(_ color: NamedColor) -> Self { ["color": .color(color)] }
}

extension Logger {
    func error(_ error: any Error) {
        let string = Logger.message(of: error)
        self.error("⚠️ \(string)", metadata: .color(.red))
    }

    private static func message(of error: any Error) -> String {
        if let error = error as? (any LocalizedError), let description = error.errorDescription {
            return description
        }

        return error.localizedDescription
    }
}

struct ScipioLogHandler: LogHandler {
    var logLevel: Logger.Level = .info
    var metadata = Logger.Metadata()

    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    func log(level: Logger.Level,
             message: Logger.Message,
             metadata: Logger.Metadata?,
             source: String,
             file: String,
             function: String,
             line: UInt) {
        let color: NamedColor?
        if let metadata = metadata,
            let rawColorString = metadata["color"],
            let colorCode = UInt8(rawColorString.description),
            let namedColor = NamedColor(rawValue: colorCode) {
            color = namedColor
        } else {
            color = nil
        }
        if let color = color {
            print(message.description.applyingColor(color))
        } else {
            print(message.description)
        }
    }
}

extension LoggingSystem {
    public static func bootstrap(logLevel: Logger.Level) {
        self.bootstrap { _ in
            var handler = ScipioLogHandler()
            handler.logLevel = logLevel
            return handler
        }
    }
}

func makeObservabilitySystem() -> ObservabilitySystem {
    ObservabilitySystem { _, diagnostics in
        switch diagnostics.severity {
        case .error:
            logger.error("\(diagnostics.message)")
        case .warning:
            logger.warning("\(diagnostics.message)")
        case .info:
            logger.info("\(diagnostics.message)")
        case .debug:
            logger.debug("\(diagnostics.message)")
        }
    }
}
