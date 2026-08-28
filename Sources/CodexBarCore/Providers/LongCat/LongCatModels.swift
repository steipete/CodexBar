import Foundation

/// LongCat's web console wraps every response in a Meituan-style envelope:
/// `{ "code": 0, "message": "...", "data": { ... } }`.
///
/// The exact `data` field names are not documented and cannot be derived from the
/// minified front-end bundle, so extraction is intentionally lenient: we walk the
/// decoded JSON trying a list of candidate keys. See `LongCatUsageFetcher`.
enum LongCatEnvelope {
    /// Returns the `data` payload if the envelope reports success, else throws.
    static func unwrap(_ object: Any?) throws -> Any {
        guard let dict = object as? [String: Any] else {
            throw LongCatAPIError.parseFailed("response was not a JSON object")
        }
        // Meituan envelopes use code == 0 for success; some surfaces use 200.
        if let code = LongCatJSON.int(dict["code"]), code != 0, code != 200 {
            let message = LongCatJSON.string(dict["message"]) ?? LongCatJSON.string(dict["msg"]) ?? "code \(code)"
            if code == 401 || code == 403 { throw LongCatAPIError.invalidSession }
            throw LongCatAPIError.apiError(message)
        }
        return dict["data"] ?? dict
    }
}

/// Tiny dynamic-JSON helper for lenient extraction by candidate key names.
enum LongCatJSON {
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: v
        case let v as Double: Int(v)
        case let v as String: Int(v) ?? Double(v).map(Int.init)
        case let v as NSNumber: v.intValue
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: v
        case let v as Int: Double(v)
        case let v as String: Double(v)
        case let v as NSNumber: v.doubleValue
        default: nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let v as String: v
        case let v as NSNumber: v.stringValue
        default: nil
        }
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        if let arr = value as? [[String: Any]] { return arr }
        if let arr = value as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
        return nil
    }

    /// First numeric value found under any of `keys`, searched at the top level
    /// and one level deep (LongCat nests some figures under `quota`/`detail`).
    static func firstNumber(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = double(object[key]) { return value }
        }
        for value in object.values {
            if let nested = value as? [String: Any] {
                for key in keys {
                    if let found = double(nested[key]) { return found }
                }
            }
        }
        return nil
    }
}
