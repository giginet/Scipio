import Foundation
import SwiftyJSON

package protocol JSONConvertible: Codable { }

extension JSONConvertible {
    init(from json: JSON) throws {
        let decoder = JSONDecoder()
        let data = try json.rawData()
        self = try decoder.decode(Self.self, from: data)
    }
}
