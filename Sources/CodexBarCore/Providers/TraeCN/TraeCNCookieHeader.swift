import Foundation

enum TraeCNCookieHeader {
    /// Keeps the full pasted cookie set (the entitlement API relies on the passport session
    /// group); normalization dedupes by name and sorts for a stable cache key.
    static func normalizedHeader(from raw: String?) -> String? {
        guard let normalized = CookieHeaderNormalizer.normalize(raw) else { return nil }
        let pairs = CookieHeaderNormalizer.pairs(from: normalized)
        guard !pairs.isEmpty else { return nil }

        var byName: [String: String] = [:]
        for pair in pairs {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            byName[name] = value
        }

        guard !byName.isEmpty else { return nil }
        return byName.keys.sorted().compactMap { name in
            guard let value = byName[name] else { return nil }
            return "\(name)=\(value)"
        }.joined(separator: "; ")
    }
}
