import Foundation
import Logging
import Rainbow
import class Basics.ObservabilitySystem

private(set) var logger = Logger(label: "me.giginet.Scipio")

extension Logger.MetadataValue {
    static func color(_ color: NamedColor) -> Self {
        .stringConvertible(color.rawValue)
    }
}

extension Logger.Metadata {
    static func color(_ color: NamedColor) -> Self { ["color": .color(color)] }
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

    init() { }

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
    public static func bootstrap() {
        self.bootstrap { _ in
            ScipioLogHandler()
        }
    }
}

func setLogLevel(_ level: Logger.Level) {
    logger.logLevel = level
}

let observabilitySystem = ObservabilitySystem { _, diagnostics in
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
