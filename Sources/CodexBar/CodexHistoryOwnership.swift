import CodexBarCore
import CryptoKit
import Foundation

enum CodexHistoryPersistedOwner: Equatable {
    case canonical(String)
    case legacyEmailHash(String)
    case legacyOpaqueScoped(String)
    case legacyUnscoped
}

enum CodexHistoryOwnership {
    private static let providerAccountPrefix = "codex:v1:provider-account:"
    private static let emailHashPrefix = "codex:v1:email-hash:"

    static func canonicalKey(for identity: CodexIdentity) -> String? {
        switch identity {
        case let .providerAccount(id):
            guard let normalized = Self.normalizeScopedValue(id) else { return nil }
            return "\(Self.providerAccountPrefix)\(normalized)"
        case let .emailOnly(normalizedEmail):
            guard let normalized = CodexIdentityResolver.normalizeEmail(normalizedEmail) else { return nil }
            return self.canonicalEmailHashKey(for: normalized)
        case .unresolved:
            return nil
        }
    }

    static func canonicalEmailHashKey(for normalizedEmail: String) -> String {
        "\(self.emailHashPrefix)\(self.legacyEmailHash(normalizedEmail: normalizedEmail))"
    }

    static func legacyEmailHash(normalizedEmail: String) -> String {
        guard let normalized = CodexIdentityResolver.normalizeEmail(normalizedEmail) else { return "" }
        return self.sha256Hex(normalized)
    }

    static func classifyPersistedKey(
        _ rawKey: String?,
        legacyEmailHash: String? = nil) -> CodexHistoryPersistedOwner
    {
        guard let normalizedKey = normalizeScopedValue(rawKey) else {
            return .legacyUnscoped
        }
        if self.isCanonicalKey(normalizedKey) {
            return .canonical(normalizedKey)
        }
        if let legacyEmailHash, normalizedKey == legacyEmailHash {
            return .legacyEmailHash(normalizedKey)
        }
        return .legacyOpaqueScoped(normalizedKey)
    }

    static func belongsToTargetContinuity(
        _ owner: CodexHistoryPersistedOwner,
        targetCanonicalKey: String,
        canonicalEmailHashKey: String?) -> Bool
    {
        switch owner {
        case let .canonical(key):
            if key == targetCanonicalKey {
                return true
            }
            guard let canonicalEmailHashKey, self.isCanonicalEmailHashKey(canonicalEmailHashKey) else {
                return false
            }
            return key == canonicalEmailHashKey
        case .legacyEmailHash:
            guard let canonicalEmailHashKey, self.isCanonicalEmailHashKey(canonicalEmailHashKey) else {
                return false
            }
            return canonicalEmailHashKey == targetCanonicalKey ||
                targetCanonicalKey.hasPrefix(self.providerAccountPrefix)
        case .legacyOpaqueScoped, .legacyUnscoped:
            return false
        }
    }

    static func hasStrictSingleAccountContinuity(
        scopedRawKeys: [String],
        targetCanonicalKey: String,
        canonicalEmailHashKey: String?,
        legacyEmailHash: String?,
        hasAdjacentMultiAccountVeto: Bool) -> Bool
    {
        guard !hasAdjacentMultiAccountVeto else { return false }

        let normalizedCandidates = Set(scopedRawKeys.compactMap { rawKey in
            let owner = self.classifyPersistedKey(rawKey, legacyEmailHash: legacyEmailHash)
            if self.belongsToTargetContinuity(
                owner,
                targetCanonicalKey: targetCanonicalKey,
                canonicalEmailHashKey: canonicalEmailHashKey)
            {
                return targetCanonicalKey
            }

            switch owner {
            case .legacyUnscoped:
                return nil
            case let .legacyOpaqueScoped(key):
                return "legacy-opaque:\(key)"
            case let .legacyEmailHash(hash):
                return "legacy-email-hash:\(hash)"
            case let .canonical(key):
                return key
            }
        })

        guard normalizedCandidates.count == 1, normalizedCandidates.first == targetCanonicalKey else {
            return false
        }
        return true
    }

    private static func isCanonicalKey(_ rawKey: String) -> Bool {
        self.isCanonicalProviderAccountKey(rawKey) || self.isCanonicalEmailHashKey(rawKey)
    }

    static func isCanonicalProviderAccountKey(_ rawKey: String) -> Bool {
        rawKey.hasPrefix(self.providerAccountPrefix) && rawKey.count > self.providerAccountPrefix.count
    }

    private static func isCanonicalEmailHashKey(_ rawKey: String) -> Bool {
        rawKey.hasPrefix(self.emailHashPrefix) && rawKey.count > self.emailHashPrefix.count
    }

    private static func normalizeScopedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
