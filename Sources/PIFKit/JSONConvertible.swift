import Foundation
import SwiftyJSON

package protocol JSONConvertible: Codable { }

extension JSONConvertible {
    init(from json: JSON) throws {
        let decoder = JSONDecoder()
        let data = try json.rawData()
        self = try decoder.decode(Self.self, from: data)
    }
    
    func toJSON(using encoder: JSONEncoder = JSONEncoder()) throws -> JSON {
        let data = try encoder.encode(self)
        return try JSON(data: data)
    }
}
