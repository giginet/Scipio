import PackageManifestKit

extension Target {
    func bundleName(for manifest: Manifest) -> String? {
        if resources.isEmpty {
            nil
        } else {
            manifest.name + "_" + name
        }
    }
}
