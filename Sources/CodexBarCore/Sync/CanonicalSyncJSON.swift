import Crypto
import Foundation

public enum CanonicalSyncJSON {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func string(_ value: some Encodable) throws -> String {
        guard let string = try String(data: self.encode(value), encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try self.decode(type, from: Data(string.utf8))
    }

    public static func hash(_ value: some Encodable) throws -> String {
        try self.hash(data: self.encode(value))
    }

    public static func hash(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CodexBarConfig {
    public func orderIndependentConfigData() throws -> Data {
        var canonical = self.normalized()
        canonical.providers.sort { $0.id.rawValue < $1.id.rawValue }
        return try CanonicalSyncJSON.encode(canonical)
    }
}
