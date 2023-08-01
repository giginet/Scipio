import XCBuildSupport

extension PIF.BuildConfiguration {
    mutating func setImpartedBuildProperties(_ newValue: PIF.ImpartedBuildProperties) {
        self = PIF.BuildConfiguration(
            guid: guid,
            name: name,
            buildSettings: buildSettings,
            impartedBuildProperties: newValue
        )
    }
}
