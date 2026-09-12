import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum VeniceCookieHeader {
    public static let sessionCookieName = "__venice-auth.session-token"

    public static func isSessionCookieName(_ name: String) -> Bool {
        if name == self.sessionCookieName {
            return true
        }
        let prefix = self.sessionCookieName + "."
        guard name.hasPrefix(prefix) else { return false }
        guard let index = Int(name.dropFirst(prefix.count)) else { return false }
        return index >= 0
    }

    public static func header(from cookies: [HTTPCookie]) -> String? {
        self.header(from: cookies.map { (name: $0.name, value: $0.value) })
    }

    public static func header(from raw: String?) -> String? {
        let pairs = CookieHeaderNormalizer.pairs(from: raw ?? "")
        return self.header(from: pairs)
    }

    public static func header(from pairs: [(name: String, value: String)]) -> String? {
        var exact: (name: String, value: String)?
        var chunks: [Int: (name: String, value: String)] = [:]

        for pair in pairs {
            let name = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty, self.isSessionCookieName(name) else { continue }
            if name == self.sessionCookieName {
                exact = (name, value)
                continue
            }
            let prefix = self.sessionCookieName + "."
            guard let index = Int(name.dropFirst(prefix.count)) else { continue }
            chunks[index] = (name, value)
        }

        if let exact {
            return "\(exact.name)=\(exact.value)"
        }
        return self.reassembledChunkHeader(chunks)
    }

    private static func reassembledChunkHeader(_ chunks: [Int: (name: String, value: String)]) -> String? {
        guard !chunks.isEmpty else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(chunks.count)
        for index in 0..<chunks.count {
            guard let chunk = chunks[index] else { return nil }
            parts.append(chunk.value)
        }
        return "\(self.sessionCookieName)=\(parts.joined())"
    }
}
