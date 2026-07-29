import Foundation

/// Recursive JSON traversal + scalar coercion helpers shared across Aliyun
/// OneConsole-based providers. The gateway responses nest subscription
/// metadata inside double-stringified JSON envelopes; these helpers walk
/// the tree without committing to a particular payload schema.
public enum OneConsoleJSON {
    /// Recursively expands any string value that itself parses as JSON,
    /// so consumers can treat `{"data": "{\"foo\": 1}"}` as if it were
    /// `{"data": {"foo": 1}}`. Non-JSON strings and primitives pass through.
    public static func expandEmbeddedJSON(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return value }
            guard let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data)
            else {
                return value
            }
            return self.expandEmbeddedJSON(decoded)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(self.expandEmbeddedJSON)
        }
        if let array = value as? [Any] {
            return array.map(self.expandEmbeddedJSON)
        }
        return value
    }

    /// Returns the first dictionary anywhere in `value` that contains any
    /// of the given keys. Useful for "find the quota object regardless of
    /// where the API nested it" parsers.
    public static func findObject(
        containingAnyOf keys: Set<String>,
        in value: Any) -> [String: Any]?
    {
        if let dictionary = value as? [String: Any] {
            if !keys.isDisjoint(with: dictionary.keys) {
                return dictionary
            }
            for nested in dictionary.values {
                if let found = self.findObject(containingAnyOf: keys, in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = self.findObject(containingAnyOf: keys, in: nested) {
                    return found
                }
            }
        }
        return nil
    }

    /// Returns the first value associated with any of `keys` anywhere in `value`.
    public static func findFirstValue(forKeys keys: [String], in value: Any) -> Any? {
        let lowercasedKeys = Set(keys.map { $0.lowercased() })
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary where lowercasedKeys.contains(key.lowercased()) {
                return nested
            }
            for nested in dictionary.values {
                if let found = self.findFirstValue(forKeys: keys, in: nested) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = self.findFirstValue(forKeys: keys, in: nested) {
                    return found
                }
            }
        }
        return nil
    }

    /// Returns the first string value associated with any of `keys` in `value`.
    public static func findFirstString(forKeys keys: [String], in value: Any) -> String? {
        for key in keys {
            if let found = self.findFirstConvertedValue(
                forKey: key,
                in: value,
                transform: self.string)
            {
                return found
            }
        }
        return nil
    }

    /// Returns the first integer value associated with any of `keys` in `value`.
    public static func findFirstInt(forKeys keys: [String], in value: Any) -> Int? {
        for key in keys {
            if let found = self.findFirstConvertedValue(
                forKey: key,
                in: value,
                transform: self.int)
            {
                return found
            }
        }
        return nil
    }

    /// Returns the first array value associated with any of `keys` in `value`.
    public static func findFirstArray(forKeys keys: [String], in value: Any) -> [Any]? {
        for key in keys {
            if let found = self.findFirstConvertedValue(
                forKey: key,
                in: value,
                transform: { $0 as? [Any] })
            {
                return found
            }
        }
        return nil
    }

    /// Searches one key at a time so caller priority is preserved across the full tree.
    /// Invalid values do not mask a later valid value for the same key.
    private static func findFirstConvertedValue<T>(
        forKey expectedKey: String,
        in value: Any,
        transform: (Any?) -> T?) -> T?
    {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary where key.caseInsensitiveCompare(expectedKey) == .orderedSame {
                if let converted = transform(nested) {
                    return converted
                }
            }
            for nested in dictionary.values {
                if let found = self.findFirstConvertedValue(
                    forKey: expectedKey,
                    in: nested,
                    transform: transform)
                {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = self.findFirstConvertedValue(
                    forKey: expectedKey,
                    in: nested,
                    transform: transform)
                {
                    return found
                }
            }
        }
        return nil
    }

    /// Coerces `value` to Double. Accepts NSNumber, Int, Double, and numeric
    /// strings. Returns nil if the value is non-numeric.
    public static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Coerces `value` to Int. Accepts NSNumber, Int, Int64, Double (truncated),
    /// and numeric strings.
    public static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int { return intValue }
        if let int64Value = value as? Int64 { return Int(int64Value) }
        if let number = value as? NSNumber { return number.intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Coerces `value` to String after trimming whitespace. Returns nil for
    /// empty or non-string values.
    public static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Converts a 0..1 ratio into a 0..100 percentage, clamping to that range.
    /// Returns nil for non-finite ratios.
    public static func percentagePoints(fromRatio ratio: Double?) -> Double? {
        guard let ratio, ratio.isFinite else { return nil }
        return min(max(ratio, 0), 1) * 100
    }

    /// Coerces `value` to a Date. Accepts:
    ///   - Positive numeric epoch in seconds or milliseconds (auto-detected via magnitude)
    ///   - ISO 8601 strings
    ///   - "yyyy-MM-dd", "yyyy-MM-dd HH:mm", and "yyyy-MM-dd HH:mm:ss" strings
    public static func date(_ value: Any?) -> Date? {
        if let number = self.number(value), number > 0 {
            let seconds = number >= 1_000_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) {
            return date
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}
