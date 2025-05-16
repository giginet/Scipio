import PackageManifestKit

extension Target.TargetKind {
    static var enabledKinds: [Self] {
        [.regular, .binary]
    }
}
