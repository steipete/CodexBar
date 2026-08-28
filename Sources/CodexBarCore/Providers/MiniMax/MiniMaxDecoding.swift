import Foundation

enum MiniMaxDecoding {
    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }
        return nil
    }

    static func decodeDouble<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        }
        return nil
    }

    static func decodeDouble<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKeys keys: [K]) -> Double? {
        for key in keys {
            if let value = self.decodeDouble(container, forKey: key) {
                return value
            }
        }
        return nil
    }
}
