import Foundation
import TSCBasic

struct InfoPlistGenerator {
    enum BundlePackageType {
        case framework
        case bundle

        var infoPlistValue: String {
            switch self {
            case .framework: return "FMWK"
            case .bundle: return "BNDL"
            }
        }
    }

    private let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    func generate(for type: BundlePackageType, at path: AbsolutePath) throws {
        let body = generateInfoPlistBody(for: type)

        try fileSystem.writeFileContents(path, string: body)
    }

    private func generateInfoPlistBody(for type: BundlePackageType) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>$(DEVELOPMENT_LANGUAGE)</string>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>$(PRODUCT_NAME)</string>
            <key>CFBundlePackageType</key>
            <string>\(type.infoPlistValue)</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
        </dict>
        </plist>
        """
    }
}
