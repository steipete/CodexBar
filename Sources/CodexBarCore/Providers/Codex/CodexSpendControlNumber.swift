import Foundation

/// The permissive numeric representation shared by Codex RPC and OAuth spend-limit payloads.
enum CodexSpendControlNumber {
    static func double<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> Double?
    {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func integer<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key) -> Int?
    {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(exactly: value.rounded(.towardZero))
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
