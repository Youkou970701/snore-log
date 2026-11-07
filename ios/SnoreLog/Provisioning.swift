import Foundation

struct Provisioning {
    static func expirationDate(data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let object = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["ExpirationDate"] as? Date
    }
    static var installedExpiration: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expirationDate(data: data)
    }
    static func expiresBeforeAlarm(expiration: Date?, alarm: Date) -> Bool {
        expiration.map { $0 <= alarm } ?? false
    }
}
