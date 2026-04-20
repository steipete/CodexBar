import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexHistoryOwnershipTests {
    private let normalizedEmail = "user@example.com"
    private let legacyEmailHash = "b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514"

    @Test
    func `serializes canonical provider-account key`() {
        let key = CodexHistoryOwnership.canonicalKey(for: .providerAccount(id: "acct-123"))

        #expect(key == "codex:v1:provider-account:acct-123")
    }

    @Test
    func `serializes canonical email-hash key`() {
        let key = CodexHistoryOwnership.canonicalKey(for: .emailOnly(normalizedEmail: self.normalizedEmail))

        #expect(key == "codex:v1:email-hash:\(self.legacyEmailHash)")
    }

    @Test
    func `unresolved identity has no canonical key`() {
        let key = CodexHistoryOwnership.canonicalKey(for: .unresolved)

        #expect(key == nil)
    }

    @Test
    func `classifies canonical and legacy persisted keys`() {
        let canonical = "codex:v1:provider-account:acct-123"
        let legacy = CodexHistoryOwnership.classifyPersistedKey(
            self.legacyEmailHash,
            legacyEmailHash: self.legacyEmailHash)
        let opaque = CodexHistoryOwnership.classifyPersistedKey(
            "92a40b0d62f5f4f1b3dbd3f9ecb6c7700dd540d2d866e59d1c110f6b4d7f1abc",
            legacyEmailHash: self.legacyEmailHash)

        #expect(CodexHistoryOwnership.classifyPersistedKey(nil) == .legacyUnscoped)
        #expect(CodexHistoryOwnership.classifyPersistedKey("") == .legacyUnscoped)
        #expect(CodexHistoryOwnership.classifyPersistedKey(canonical) == .canonical(canonical))
        #expect(legacy == .legacyEmailHash(self.legacyEmailHash))
        #expect(opaque == .legacyOpaqueScoped("92a40b0d62f5f4f1b3dbd3f9ecb6c7700dd540d2d866e59d1c110f6b4d7f1abc"))
    }

    @Test
    func `strict continuity passes for a single aliased email-hash owner`() {
        let canonicalEmailHashKey = "codex:v1:email-hash:\(self.legacyEmailHash)"

        let result = CodexHistoryOwnership.hasStrictSingleAccountContinuity(
            scopedRawKeys: [self.legacyEmailHash],
            targetCanonicalKey: canonicalEmailHashKey,
            canonicalEmailHashKey: canonicalEmailHashKey,
            legacyEmailHash: self.legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(result)
    }

    @Test
    func `strict continuity fails with ambiguous owners`() {
        let canonicalEmailHashKey = "codex:v1:email-hash:\(self.legacyEmailHash)"

        let result = CodexHistoryOwnership.hasStrictSingleAccountContinuity(
            scopedRawKeys: [
                canonicalEmailHashKey,
                "codex:v1:provider-account:acct-123",
            ],
            targetCanonicalKey: canonicalEmailHashKey,
            canonicalEmailHashKey: canonicalEmailHashKey,
            legacyEmailHash: self.legacyEmailHash,
            hasAdjacentMultiAccountVeto: false)

        #expect(!result)
    }

    @Test
    func `strict continuity fails when adjacent persisted evidence vetoes migration`() {
        let canonicalEmailHashKey = "codex:v1:email-hash:\(self.legacyEmailHash)"

        let result = CodexHistoryOwnership.hasStrictSingleAccountContinuity(
            scopedRawKeys: [canonicalEmailHashKey],
            targetCanonicalKey: canonicalEmailHashKey,
            canonicalEmailHashKey: canonicalEmailHashKey,
            legacyEmailHash: self.legacyEmailHash,
            hasAdjacentMultiAccountVeto: true)

        #expect(!result)
    }

    @Test
    func `provider-account target inherits email continuity`() {
        let providerAccountKey = "codex:v1:provider-account:acct-123"
        let canonicalEmailHashKey = "codex:v1:email-hash:\(self.legacyEmailHash)"

        let legacyMatchesProvider = CodexHistoryOwnership.belongsToTargetContinuity(
            .legacyEmailHash(self.legacyEmailHash),
            targetCanonicalKey: providerAccountKey,
            canonicalEmailHashKey: canonicalEmailHashKey)
        let canonicalMatchesProvider = CodexHistoryOwnership.belongsToTargetContinuity(
            .canonical(canonicalEmailHashKey),
            targetCanonicalKey: providerAccountKey,
            canonicalEmailHashKey: canonicalEmailHashKey)

        #expect(legacyMatchesProvider)
        #expect(canonicalMatchesProvider)
    }
}
