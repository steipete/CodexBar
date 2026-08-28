import Foundation

public struct ProviderInstanceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String {
        self.rawValue
    }

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(firstPartyProvider provider: UsageProvider) {
        self.rawValue = provider.rawValue
    }

    public var firstPartyProvider: UsageProvider? {
        UsageProvider(rawValue: self.rawValue)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let instanceID = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Provider instance ID must contain 1-64 lowercase ASCII letters, digits, or hyphens")
        }
        self = instanceID
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    private static func isValid(_ rawValue: String) -> Bool {
        guard (1...64).contains(rawValue.utf8.count) else { return false }
        return rawValue.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                byte == UInt8(ascii: "-")
        }
    }
}

extension UsageProvider {
    public var instanceID: ProviderInstanceID {
        ProviderInstanceID(firstPartyProvider: self)
    }
}
