import CodexBarCore
import Foundation
import Testing

struct CodexProviderSettingsBuilderTests {
    @Test
    func `builder keeps managed store unreadable fail closed when selection resolves back to live system`() {
        let selectedManagedID = UUID()
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: ObservedSystemCodexAccount(
                email: "live@example.com",
                codexHomePath: "/tmp/live",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-live")),
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: selectedManagedID),
            hasUnreadableAddedAccountStore: true)

        let settings = CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: .auto,
            manualCookieHeader: nil,
            reconciliationSnapshot: snapshot,
            resolvedActiveSource: CodexActiveSourceResolver.resolve(from: snapshot)))

        #expect(settings.managedAccountStoreUnreadable == true)
        #expect(settings.managedAccountTargetUnavailable == false)
    }

    @Test
    func `builder marks missing selected managed account as unavailable`() {
        let selectedManagedID = UUID()
        let otherStoredAccount = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            managedHomePath: "/tmp/other",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [otherStoredAccount],
            activeStoredAccount: nil,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: selectedManagedID),
            hasUnreadableAddedAccountStore: false)

        let settings = CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: .auto,
            manualCookieHeader: nil,
            reconciliationSnapshot: snapshot,
            resolvedActiveSource: CodexActiveSourceResolver.resolve(from: snapshot)))

        #expect(settings.managedAccountStoreUnreadable == false)
        #expect(settings.managedAccountTargetUnavailable == true)
    }

    @Test
    func `builder keeps missing managed target fail closed when selection resolves back to live system`() {
        let selectedManagedID = UUID()
        let otherStoredAccount = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            managedHomePath: "/tmp/other",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [otherStoredAccount],
            activeStoredAccount: nil,
            liveSystemAccount: ObservedSystemCodexAccount(
                email: "live@example.com",
                codexHomePath: "/tmp/live",
                observedAt: Date(),
                identity: .providerAccount(id: "acct-live")),
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: selectedManagedID),
            hasUnreadableAddedAccountStore: false)

        let settings = CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: .auto,
            manualCookieHeader: nil,
            reconciliationSnapshot: snapshot,
            resolvedActiveSource: CodexActiveSourceResolver.resolve(from: snapshot)))

        #expect(settings.managedAccountStoreUnreadable == false)
        #expect(settings.managedAccountTargetUnavailable == true)
    }

    @Test
    func `builder marks profile without observed account as unavailable`() {
        let profilePath = "/tmp/codex-profile-missing-auth"
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: nil,
            profileHomeAccounts: [],
            profileHomePaths: [profilePath],
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .profileHome(path: profilePath),
            hasUnreadableAddedAccountStore: false)

        let settings = CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: .auto,
            manualCookieHeader: nil,
            reconciliationSnapshot: snapshot,
            resolvedActiveSource: CodexActiveSourceResolver.resolve(from: snapshot)))

        #expect(settings.profileAccountTargetUnavailable)
        #expect(settings.openAIWebCacheScope == .profileHome(profilePath))
    }

    @Test
    func `known owner catalog includes runtime managed and live identities`() {
        let storedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let liveSystemAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/tmp/live",
            observedAt: Date(),
            identity: .providerAccount(id: "acct-live"))
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [storedAccount],
            activeStoredAccount: storedAccount,
            liveSystemAccount: liveSystemAccount,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .managedAccount(id: storedAccount.id),
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: [storedAccount.id: .providerAccount(id: "acct-managed")],
            storedAccountRuntimeEmails: [storedAccount.id: "managed-runtime@example.com"])

        let candidates = CodexKnownOwnerCatalog.candidates(from: snapshot)

        #expect(candidates.count == 2)
        #expect(candidates.contains(CodexDashboardKnownOwnerCandidate(
            identity: .providerAccount(id: "acct-managed"),
            normalizedEmail: "managed-runtime@example.com")))
        #expect(candidates.contains(CodexDashboardKnownOwnerCandidate(
            identity: .providerAccount(id: "acct-live"),
            normalizedEmail: "live@example.com")))
    }

    @Test
    func `builder preserves same email profile owners and scopes web cache`() {
        let profileA = ObservedSystemCodexAccount(
            email: "shared@example.com",
            codexHomePath: "/tmp/codex-profile-a",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "shared@example.com"))
        let profileB = ObservedSystemCodexAccount(
            email: "shared@example.com",
            codexHomePath: "/tmp/codex-profile-b",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "shared@example.com"))
        let snapshot = CodexAccountReconciliationSnapshot(
            storedAccounts: [],
            activeStoredAccount: nil,
            liveSystemAccount: nil,
            profileHomeAccounts: [profileA, profileB],
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: .profileHome(path: profileA.codexHomePath),
            hasUnreadableAddedAccountStore: false)

        let settings = CodexProviderSettingsBuilder.make(input: CodexProviderSettingsBuilderInput(
            usageDataSource: .auto,
            cookieSource: .auto,
            manualCookieHeader: nil,
            reconciliationSnapshot: snapshot,
            resolvedActiveSource: CodexActiveSourceResolver.resolve(from: snapshot)))

        #expect(settings.openAIWebCacheScope == .profileHome(profileA.codexHomePath))
        #expect(!settings.profileAccountTargetUnavailable)
        #expect(settings.dashboardAuthorityKnownOwners.count == 2)
        #expect(Set(settings.dashboardAuthorityKnownOwners.map(\.sourceIsolationIdentifier)).count == 2)

        let decision = CodexDashboardAuthority.evaluate(CodexDashboardAuthorityInput(
            sourceKind: .liveWeb,
            proof: CodexDashboardOwnershipProofContext(
                currentIdentity: .emailOnly(normalizedEmail: "shared@example.com"),
                expectedScopedEmail: "shared@example.com",
                trustedCurrentUsageEmail: nil,
                dashboardSignedInEmail: "shared@example.com",
                knownOwners: settings.dashboardAuthorityKnownOwners),
            routing: CodexDashboardRoutingHints(
                targetEmail: "shared@example.com",
                lastKnownDashboardRoutingEmail: nil)))
        #expect(decision.disposition == .displayOnly)
        #expect(decision.reason == .sameEmailAmbiguity(email: "shared@example.com"))
    }
}
