import Foundation
import SwiftyJSON

package struct Target: Sendable, Codable, Equatable, JSONConvertible {
    package enum ProductType: String, Codable, Equatable, Sendable {
        case application = "com.apple.product-type.application"
        case staticArchive = "com.apple.product-type.library.static"
        case objectFile = "com.apple.product-type.objfile"
        case dynamicLibrary = "com.apple.product-type.library.dynamic"
        case framework = "com.apple.product-type.framework"
        case executable = "com.apple.product-type.tool"
        case unitTest = "com.apple.product-type.bundle.unit-test"
        case bundle = "com.apple.product-type.bundle"
        case packageProduct = "packageProduct"
    }
    
    package var name: String
    package var buildConfigurations: [BuildConfiguration]
    package var productType: ProductType?
    
    enum CodingKeys: String, CodingKey {
        case name
        case buildConfigurations
        case productType = "productTypeIdentifier"
    }
}
