import CodexBarCore
import Testing

struct CodexDashboardAuthorityTests {
    @Test
    func `email only wrong email returns fail closed`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .emailOnly(normalizedEmail: "owner@example.com"),
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "other@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .emailOnly(normalizedEmail: "owner@example.com"),
                        normalizedEmail: "owner@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .failClosed)
        #expect(decision.reason == .wrongEmail(expected: "owner@example.com", actual: "other@example.com"))
    }

    @Test
    func `provider account wrong email returns fail closed`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "acct-owner"),
                expectedScopedEmail: "owner@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "other@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-owner"),
                        normalizedEmail: "owner@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: "stale@example.com"))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .failClosed)
        #expect(decision.reason == .wrongEmail(expected: "owner@example.com", actual: "other@example.com"))
    }

    @Test
    func `email only same email ambiguity returns display only`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .emailOnly(normalizedEmail: "shared@example.com"),
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "shared@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-beta"),
                        normalizedEmail: "shared@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "shared@example.com",
                lastKnownDashboardRoutingEmail: "shared@example.com"))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .displayOnly)
        #expect(decision.reason == .sameEmailAmbiguity(email: "shared@example.com"))
    }

    @Test
    func `provider account exact owner match returns attach`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "acct-owner"),
                expectedScopedEmail: "OWNER@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "owner@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-owner"),
                        normalizedEmail: "OWNER@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-other"),
                        normalizedEmail: "other@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "route@example.com",
                lastKnownDashboardRoutingEmail: "stale@example.com"))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .attach)
        #expect(decision.reason == .exactProviderAccountMatch)
    }

    @Test
    func `provider account same email ambiguity without exact match returns display only`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "acct-current"),
                expectedScopedEmail: "shared@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "shared@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-beta"),
                        normalizedEmail: "shared@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "shared@example.com",
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .displayOnly)
        #expect(decision.reason == .sameEmailAmbiguity(email: "shared@example.com"))
    }

    @Test
    func `provider account nil scoped email with dashboard collision returns fail closed`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "acct-current"),
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: "shared@example.com",
                dashboardSignedInEmail: "shared@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-beta"),
                        normalizedEmail: "shared@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "shared@example.com",
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .failClosed)
        #expect(decision.reason == .providerAccountMissingScopedEmail)
    }

    @Test
    func `unresolved trusted continuity without competing owner returns attach`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .unresolved,
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: "owner@example.com",
                dashboardSignedInEmail: "owner@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-owner"),
                        normalizedEmail: "owner@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: "route@example.com"))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .attach)
        #expect(decision.reason == .trustedContinuityNoCompetingOwner)
    }

    @Test
    func `unresolved trusted continuity with competing owner returns display only`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .unresolved,
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: "shared@example.com",
                dashboardSignedInEmail: "shared@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-beta"),
                        normalizedEmail: "shared@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "shared@example.com",
                lastKnownDashboardRoutingEmail: "route@example.com"))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .displayOnly)
        #expect(decision.reason == .sameEmailAmbiguity(email: "shared@example.com"))
    }

    @Test
    func `unresolved without trusted evidence returns fail closed`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .unresolved,
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "owner@example.com",
                knownOwners: []),
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .failClosed)
        #expect(decision.reason == .unresolvedWithoutTrustedEvidence)
    }

    @Test
    func `missing dashboard signed in email returns fail closed`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "acct-owner"),
                expectedScopedEmail: "owner@example.com",
                trustedCurrentUsageEmail: "owner@example.com",
                dashboardSignedInEmail: nil,
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-owner"),
                        normalizedEmail: "owner@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .failClosed)
        #expect(decision.reason == .missingDashboardSignedInEmail)
    }

    @Test
    func `live web attach exposes usage credits guard and history effects`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .providerAccount(id: "acct-owner"),
                expectedScopedEmail: "owner@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "owner@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-owner"),
                        normalizedEmail: "owner@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: nil,
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .attach)
        #expect(decision.allowedEffects == Set([
            .usageBackfill,
            .creditsAttachment,
            .refreshGuardSeed,
            .historicalBackfill,
        ]))
        #expect(decision.cleanup.isEmpty)
    }

    @Test
    func `cached dashboard attach exposes cached reuse only`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .cachedDashboard,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .emailOnly(normalizedEmail: "owner@example.com"),
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "owner@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-owner"),
                        normalizedEmail: "owner@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .attach)
        #expect(decision.allowedEffects == Set([.cachedDashboardReuse]))
        #expect(decision.cleanup.isEmpty)
    }

    @Test
    func `display only emits full cleanup set`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .emailOnly(normalizedEmail: "shared@example.com"),
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "shared@example.com",
                knownOwners: [
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-alpha"),
                        normalizedEmail: "shared@example.com"),
                    CodexDashboardKnownOwnerCandidate(
                        identity: .providerAccount(id: "acct-beta"),
                        normalizedEmail: "shared@example.com"),
                ]),
            routing: CodexDashboardRoutingHints(
                targetEmail: nil,
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .displayOnly)
        #expect(decision.allowedEffects.isEmpty)
        #expect(decision.cleanup == Set(CodexDashboardCleanup.allCases))
    }

    @Test
    func `fail closed emits full cleanup set`() {
        let input = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .unresolved,
                expectedScopedEmail: nil,
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "owner@example.com",
                knownOwners: []),
            routing: CodexDashboardRoutingHints(
                targetEmail: nil,
                lastKnownDashboardRoutingEmail: nil))

        let decision = CodexDashboardAuthority.evaluate(input)

        #expect(decision.disposition == .failClosed)
        #expect(decision.allowedEffects.isEmpty)
        #expect(decision.cleanup == Set(CodexDashboardCleanup.allCases))
    }

    @Test
    func `routing hints do not change evaluation result`() {
        let proof = CodexDashboardOwnershipProofContext(
            currentIdentity: .providerAccount(id: "acct-owner"),
            expectedScopedEmail: "owner@example.com",
            trustedCurrentUsageEmail: nil,
            dashboardSignedInEmail: "owner@example.com",
            knownOwners: [
                CodexDashboardKnownOwnerCandidate(
                    identity: .providerAccount(id: "acct-owner"),
                    normalizedEmail: "owner@example.com"),
            ])
        let baseInput = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: proof,
            routing: CodexDashboardRoutingHints(
                targetEmail: "owner@example.com",
                lastKnownDashboardRoutingEmail: "owner@example.com"))
        let conflictingRoutingInput = CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: proof,
            routing: CodexDashboardRoutingHints(
                targetEmail: "wrong@example.com",
                lastKnownDashboardRoutingEmail: "stale@example.com"))

        let baseDecision = CodexDashboardAuthority.evaluate(baseInput)
        let conflictingDecision = CodexDashboardAuthority.evaluate(conflictingRoutingInput)

        #expect(baseDecision == conflictingDecision)
    }
}
