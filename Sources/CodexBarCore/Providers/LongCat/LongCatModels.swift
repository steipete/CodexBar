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
        if let rawCode = dict["code"] {
            guard let code = LongCatJSON.int(rawCode) else {
                throw LongCatAPIError.parseFailed("response code was not a valid integer")
            }
            guard code != 0, code != 200 else { return dict["data"] ?? dict }
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
        case let v as Double: Int(exactly: v.rounded(.towardZero))
        case let v as String: Int(v) ?? Double(v).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        case let v as NSNumber: Int(exactly: v.doubleValue.rounded(.towardZero))
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
}
