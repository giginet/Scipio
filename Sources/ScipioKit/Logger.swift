import Foundation
import Logging
import class Basics.ObservabilitySystem

let logger = Logger(label: "me.giginet.Scipio")

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
