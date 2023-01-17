import Foundation

enum XCConfigValue {
    case string(String)
    case list([XCConfigValue])
    case bool(Bool)

    static func list(_ stringList: [String]) -> Self {
        return .list(stringList.map(XCConfigValue.init(stringLiteral:)))
    }

    static let inherited: Self = .string("$(inherited)")

    var rawConfigValue: Any {
        switch self {
        case .string(let rawString): return rawString
        case .bool(let bool): return bool
        case .list(let list): return list.map(\.rawConfigValue)
        }
    }
}

extension XCConfigValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: BooleanLiteralType) {
        self = .bool(value)
    }
}

extension XCConfigValue: ExpressibleByStringLiteral {
    init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

extension XCConfigValue: ExpressibleByArrayLiteral {
    typealias ArrayLiteralElement = XCConfigValue

    init(arrayLiteral elements: ArrayLiteralElement...) {
        self = .list(elements)
    }
}

extension [String: XCConfigValue] {
    mutating func merge(_ other: Self) {
        let allKeys = Set(self.keys).union(other.keys)
        for key in allKeys {
            switch (self[key], other[key]) {
            case (.some, .none):
                continue
            case (.none, .some(let rhs)):
                self[key] = rhs
            case (.some(.list(let lhs)), .some(.list(let rhs))):
                self[key] = .list(lhs + rhs)
            case (.some(.string(let lhs)), .some(.string(let rhs))):
                self[key] = .list([lhs, rhs])
            case (.some(.list(let lhs)), .some(.string(let rhs))):
                self[key] = .list(lhs + [.string(rhs)])
            case (.some(.string(let lhs)), .some(.list(let rhs))):
                self[key] = .list([.string(lhs)] + rhs)
            default:
                continue
            }
        }
    }
}
