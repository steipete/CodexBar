import Foundation

public enum CodexDashboardSourceKind: String, Codable, Sendable {
    case liveWeb
    case cachedDashboard
}

public enum CodexDashboardDisposition: String, Codable, Sendable {
    case attach
    case displayOnly
    case failClosed
}

public enum CodexDashboardAllowedEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case usageBackfill
    case creditsAttachment
    case refreshGuardSeed
    case historicalBackfill
    case cachedDashboardReuse
}

public enum CodexDashboardCleanup: String, Codable, CaseIterable, Hashable, Sendable {
    case dashboardSnapshot
    case dashboardDerivedUsage
    case dashboardDerivedCredits
    case dashboardRefreshGuardSeed
    case dashboardCache
}

public struct CodexDashboardKnownOwnerCandidate: Equatable, Hashable, Sendable {
    public let identity: CodexIdentity
    public let normalizedEmail: String?

    public init(identity: CodexIdentity, normalizedEmail: String?) {
        self.identity = identity
        self.normalizedEmail = normalizedEmail
    }

    public func hash(into hasher: inout Hasher) {
        switch self.identity {
        case let .providerAccount(id):
            hasher.combine("providerAccount")
            hasher.combine(id)
        case let .emailOnly(normalizedEmail):
            hasher.combine("emailOnly")
            hasher.combine(normalizedEmail)
        case .unresolved:
            hasher.combine("unresolved")
        }
        hasher.combine(self.normalizedEmail)
    }
}

public struct CodexDashboardOwnershipProofContext: Equatable, Sendable {
    public let currentIdentity: CodexIdentity
    public let expectedScopedEmail: String?
    public let trustedCurrentUsageEmail: String?
    public let dashboardSignedInEmail: String?
    public let knownOwners: [CodexDashboardKnownOwnerCandidate]

    public init(
        currentIdentity: CodexIdentity,
        expectedScopedEmail: String?,
        trustedCurrentUsageEmail: String?,
        dashboardSignedInEmail: String?,
        knownOwners: [CodexDashboardKnownOwnerCandidate])
    {
        self.currentIdentity = currentIdentity
        self.expectedScopedEmail = expectedScopedEmail
        self.trustedCurrentUsageEmail = trustedCurrentUsageEmail
        self.dashboardSignedInEmail = dashboardSignedInEmail
        self.knownOwners = knownOwners
    }
}

public struct CodexDashboardRoutingHints: Equatable, Sendable {
    public let targetEmail: String?
    public let lastKnownDashboardRoutingEmail: String?

    public init(targetEmail: String?, lastKnownDashboardRoutingEmail: String?) {
        self.targetEmail = targetEmail
        self.lastKnownDashboardRoutingEmail = lastKnownDashboardRoutingEmail
    }
}

public struct CodexDashboardAuthorityInput: Equatable, Sendable {
    public let sourceKind: CodexDashboardSourceKind
    public let proof: CodexDashboardOwnershipProofContext
    public let routing: CodexDashboardRoutingHints

    public init(
        sourceKind: CodexDashboardSourceKind,
        proof: CodexDashboardOwnershipProofContext,
        routing: CodexDashboardRoutingHints)
    {
        self.sourceKind = sourceKind
        self.proof = proof
        self.routing = routing
    }
}

public enum CodexDashboardDecisionReason: Equatable, Sendable {
    case exactProviderAccountMatch
    case trustedEmailMatchNoCompetingOwner
    case trustedContinuityNoCompetingOwner
    case wrongEmail(expected: String?, actual: String?)
    case sameEmailAmbiguity(email: String)
    case unresolvedWithoutTrustedEvidence
    case providerAccountMissingScopedEmail
    case providerAccountLacksExactOwnershipProof
    case missingDashboardSignedInEmail
}

public struct CodexDashboardAuthorityDecision: Equatable, Sendable {
    public let disposition: CodexDashboardDisposition
    public let reason: CodexDashboardDecisionReason
    public let allowedEffects: Set<CodexDashboardAllowedEffect>
    public let cleanup: Set<CodexDashboardCleanup>

    public init(
        disposition: CodexDashboardDisposition,
        reason: CodexDashboardDecisionReason,
        allowedEffects: Set<CodexDashboardAllowedEffect>,
        cleanup: Set<CodexDashboardCleanup>)
    {
        self.disposition = disposition
        self.reason = reason
        self.allowedEffects = allowedEffects
        self.cleanup = cleanup
    }
}

public enum CodexDashboardPolicyError: LocalizedError, Equatable, Sendable {
    case displayOnly(CodexDashboardAuthorityDecision)

    public var errorDescription: String? {
        switch self {
        case .displayOnly:
            "Codex dashboard may be displayed, but it cannot be attached to the active account."
        }
    }
}

public enum CodexDashboardAuthority {
    /// Evaluates whether a Codex dashboard snapshot may attach to the active account.
    ///
    /// App callers may keep `.displayOnly` dashboard data visible, but must not attach usage,
    /// credits, refresh guards, or historical backfill.
    ///
    /// CLI callers should surface `.displayOnly` as `CodexDashboardPolicyError.displayOnly`
    /// instead of treating it as a generic failure.
    ///
    /// Cached dashboard callers may restore data only when the decision includes
    /// `.cachedDashboardReuse` in `allowedEffects`.
    public static func evaluate(_ input: CodexDashboardAuthorityInput) -> CodexDashboardAuthorityDecision {
        let proof = input.proof
        let currentIdentity = Self.normalizeIdentity(proof.currentIdentity)
        let expectedScopedEmail = CodexIdentityResolver.normalizeEmail(proof.expectedScopedEmail)
        let trustedCurrentUsageEmail = CodexIdentityResolver.normalizeEmail(proof.trustedCurrentUsageEmail)
        let dashboardSignedInEmail = CodexIdentityResolver.normalizeEmail(proof.dashboardSignedInEmail)
        let knownOwners = Self.normalizeKnownOwners(proof.knownOwners)

        // Routing hints are intentionally excluded from ownership proof. They may help fetch or route
        // dashboard requests, but they must never influence attach/display/fail-closed policy.

        guard let dashboardSignedInEmail else {
            return Self.makeDecision(
                disposition: .failClosed,
                reason: .missingDashboardSignedInEmail,
                sourceKind: input.sourceKind)
        }

        if let expectedScopedEmail, dashboardSignedInEmail != expectedScopedEmail {
            return Self.makeDecision(
                disposition: .failClosed,
                reason: .wrongEmail(expected: expectedScopedEmail, actual: dashboardSignedInEmail),
                sourceKind: input.sourceKind)
        }

        switch currentIdentity {
        case let .providerAccount(id):
            let exactMatch = knownOwners.contains { candidate in
                candidate.identity == .providerAccount(id: id) && candidate.normalizedEmail == dashboardSignedInEmail
            }
            if exactMatch {
                return Self.makeDecision(
                    disposition: .attach,
                    reason: .exactProviderAccountMatch,
                    sourceKind: input.sourceKind)
            }
            guard expectedScopedEmail != nil else {
                return Self.makeDecision(
                    disposition: .failClosed,
                    reason: .providerAccountMissingScopedEmail,
                    sourceKind: input.sourceKind)
            }
            if Self.knownOwnerCount(for: dashboardSignedInEmail, in: knownOwners) > 1 {
                return Self.makeDecision(
                    disposition: .displayOnly,
                    reason: .sameEmailAmbiguity(email: dashboardSignedInEmail),
                    sourceKind: input.sourceKind)
            }
            return Self.makeDecision(
                disposition: .failClosed,
                reason: .providerAccountLacksExactOwnershipProof,
                sourceKind: input.sourceKind)

        case let .emailOnly(normalizedEmail):
            guard dashboardSignedInEmail == normalizedEmail else {
                return Self.makeDecision(
                    disposition: .failClosed,
                    reason: .wrongEmail(expected: normalizedEmail, actual: dashboardSignedInEmail),
                    sourceKind: input.sourceKind)
            }
            if Self.knownOwnerCount(for: normalizedEmail, in: knownOwners) > 1 {
                return Self.makeDecision(
                    disposition: .displayOnly,
                    reason: .sameEmailAmbiguity(email: normalizedEmail),
                    sourceKind: input.sourceKind)
            }
            return Self.makeDecision(
                disposition: .attach,
                reason: .trustedEmailMatchNoCompetingOwner,
                sourceKind: input.sourceKind)

        case .unresolved:
            guard let trustedCurrentUsageEmail else {
                return Self.makeDecision(
                    disposition: .failClosed,
                    reason: .unresolvedWithoutTrustedEvidence,
                    sourceKind: input.sourceKind)
            }
            guard dashboardSignedInEmail == trustedCurrentUsageEmail else {
                return Self.makeDecision(
                    disposition: .failClosed,
                    reason: .wrongEmail(expected: trustedCurrentUsageEmail, actual: dashboardSignedInEmail),
                    sourceKind: input.sourceKind)
            }
            if Self.knownOwnerCount(for: trustedCurrentUsageEmail, in: knownOwners) > 1 {
                return Self.makeDecision(
                    disposition: .displayOnly,
                    reason: .sameEmailAmbiguity(email: trustedCurrentUsageEmail),
                    sourceKind: input.sourceKind)
            }
            return Self.makeDecision(
                disposition: .attach,
                reason: .trustedContinuityNoCompetingOwner,
                sourceKind: input.sourceKind)
        }
    }

    private static func normalizeIdentity(_ identity: CodexIdentity) -> CodexIdentity {
        switch identity {
        case let .providerAccount(id):
            if let normalizedID = CodexIdentityResolver.normalizeAccountID(id) {
                return .providerAccount(id: normalizedID)
            }
            return .unresolved
        case let .emailOnly(normalizedEmail):
            if let normalizedEmail = CodexIdentityResolver.normalizeEmail(normalizedEmail) {
                return .emailOnly(normalizedEmail: normalizedEmail)
            }
            return .unresolved
        case .unresolved:
            return .unresolved
        }
    }

    private static func normalizeKnownOwners(
        _ candidates: [CodexDashboardKnownOwnerCandidate])
        -> Set<CodexDashboardKnownOwnerCandidate>
    {
        Set(candidates.map { candidate in
            CodexDashboardKnownOwnerCandidate(
                identity: self.normalizeIdentity(candidate.identity),
                normalizedEmail: CodexIdentityResolver.normalizeEmail(candidate.normalizedEmail))
        })
    }

    private static func knownOwnerCount(
        for email: String,
        in candidates: Set<CodexDashboardKnownOwnerCandidate>) -> Int
    {
        candidates.count { $0.normalizedEmail == email }
    }

    private static func makeDecision(
        disposition: CodexDashboardDisposition,
        reason: CodexDashboardDecisionReason,
        sourceKind: CodexDashboardSourceKind) -> CodexDashboardAuthorityDecision
    {
        CodexDashboardAuthorityDecision(
            disposition: disposition,
            reason: reason,
            allowedEffects: self.allowedEffects(disposition: disposition, sourceKind: sourceKind),
            cleanup: disposition == .attach ? [] : Set(CodexDashboardCleanup.allCases))
    }

    private static func allowedEffects(
        disposition: CodexDashboardDisposition,
        sourceKind: CodexDashboardSourceKind) -> Set<CodexDashboardAllowedEffect>
    {
        guard disposition == .attach else { return [] }

        switch sourceKind {
        case .liveWeb:
            return [
                .usageBackfill,
                .creditsAttachment,
                .refreshGuardSeed,
                .historicalBackfill,
            ]
        case .cachedDashboard:
            return [.cachedDashboardReuse]
        }
    }
}
