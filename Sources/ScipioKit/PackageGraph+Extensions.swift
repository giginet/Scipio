import Foundation
import PackageGraph

extension ResolvedTarget {
    var xcFrameworkName: String {
        "\(c99name.packageNamed()).xcframework"
    }
}
