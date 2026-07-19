import Foundation
import Testing
@testable import CodexBarCore

// MARK: - Descriptor Tests

struct AbacusDescriptorTests {
    @Test
    func `descriptor has correct identity`() {
        let descriptor = AbacusProviderDescriptor.descriptor
        #expect(descriptor.id == .abacus)
        #expect(descriptor.metadata.displayName == "Abacus AI")
        #expect(descriptor.metadata.cliName == "abacusai")
    }

    @Test
    func `descriptor does not expose a separate credits panel`() {
        let meta = AbacusProviderDescriptor.descriptor.metadata
        #expect(meta.supportsCredits == false)
        #expect(meta.supportsOpus == false)
    }

    @Test
    func `descriptor is not primary provider`() {
        let meta = AbacusProviderDescriptor.descriptor.metadata
        #expect(meta.isPrimaryProvider == false)
        #expect(meta.defaultEnabled == false)
    }

    @Test
    func `descriptor supports auto and web source modes`() {
        let descriptor = AbacusProviderDescriptor.descriptor
        #expect(descriptor.fetchPlan.sourceModes.contains(.auto))
        #expect(descriptor.fetchPlan.sourceModes.contains(.web))
    }

    @Test
    func `descriptor has no version detector`() {
        let descriptor = AbacusProviderDescriptor.descriptor
        #expect(descriptor.cli.versionDetector == nil)
    }

    @Test
    func `descriptor does not support token cost`() {
        let descriptor = AbacusProviderDescriptor.descriptor
        #expect(descriptor.tokenCost.supportsTokenCost == false)
    }

    @Test
    func `cli aliases include abacus-ai`() {
        let descriptor = AbacusProviderDescriptor.descriptor
        #expect(descriptor.cli.aliases.contains("abacus-ai"))
    }

    @Test
    func `dashboard url points to compute points page`() {
        let meta = AbacusProviderDescriptor.descriptor.metadata
        #expect(meta.dashboardURL?.contains("compute-points") == true)
    }
}

// MARK: - Usage Snapshot Conversion Tests

struct AbacusUsageSnapshotTests {
    @Test
    func `converts full snapshot to usage snapshot`() throws {
        let resetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 250,
            creditsTotal: 1000,
            resetsAt: resetDate,
            planName: "Pro")

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary != nil)
        #expect(abs((usage.primary?.usedPercent ?? 0) - 25.0) < 0.01)
        #expect(usage.primary?.resetDescription == "250 / 1,000 credits")
        #expect(usage.primary?.resetsAt == resetDate)
        // Window derived from actual billing cycle (1 calendar month before resetDate)
        let cycleStart = try #require(Calendar.current.date(byAdding: .month, value: -1, to: resetDate))
        let expectedMinutes = Int(resetDate.timeIntervalSince(cycleStart) / 60)
        #expect(usage.primary?.windowMinutes == expectedMinutes)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.identity?.providerID == .abacus)
        #expect(usage.identity?.loginMethod == "Pro")
    }

    @Test
    func `handles zero usage`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 500,
            resetsAt: nil,
            planName: "Basic")

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0.0)
        #expect(usage.primary?.resetDescription == "0 / 500 credits")
    }

    @Test
    func `handles full usage`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 1000,
            creditsTotal: 1000,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(abs((usage.primary?.usedPercent ?? 0) - 100.0) < 0.01)
        #expect(usage.primary?.resetDescription == "1,000 / 1,000 credits")
    }

    @Test
    func `handles nil credits gracefully`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: nil,
            creditsTotal: nil,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0.0)
        #expect(usage.primary?.resetDescription == nil)
    }

    @Test
    func `handles nil total with non-nil used`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 100,
            creditsTotal: nil,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0.0)
    }

    @Test
    func `handles zero total credits`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 0,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0.0)
    }

    @Test
    func `formats large credit values with comma grouping`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 12345,
            creditsTotal: 50000,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.resetDescription == "12,345 / 50,000 credits")
    }

    @Test
    func `formats fractional credit values`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 42.5,
            creditsTotal: 100,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.resetDescription == "42.5 / 100 credits")
    }

    @Test
    func `window minutes represents monthly cycle`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 100,
            resetsAt: nil,
            planName: nil)

        let usage = snapshot.toUsageSnapshot()
        // 30 days * 24 hours * 60 minutes = 43200
        #expect(usage.primary?.windowMinutes == 43200)
    }

    @Test
    func `identity has no email or organization`() {
        let snapshot = AbacusUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 100,
            resetsAt: nil,
            planName: "Pro")

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.accountEmail == nil)
        #expect(usage.identity?.accountOrganization == nil)
    }
}

// MARK: - Error Description Tests

struct AbacusErrorTests {
    @Test
    func `noSessionCookie error mentions login`() {
        let error = AbacusUsageError.noSessionCookie
        #expect(error.errorDescription?.contains("log in") == true)
    }

    @Test
    func `sessionExpired error mentions expired`() {
        let error = AbacusUsageError.sessionExpired
        #expect(error.errorDescription?.contains("expired") == true)
    }

    @Test
    func `networkError includes message`() {
        let error = AbacusUsageError.networkError("HTTP 500")
        #expect(error.errorDescription?.contains("HTTP 500") == true)
    }

    @Test
    func `parseFailed includes message`() {
        let error = AbacusUsageError.parseFailed("Invalid JSON")
        #expect(error.errorDescription?.contains("Invalid JSON") == true)
    }

    @Test
    func `unauthorized error mentions login`() {
        let error = AbacusUsageError.unauthorized
        #expect(error.errorDescription?.contains("log in") == true)
    }
}

// MARK: - Error Classification Tests

struct AbacusErrorClassificationTests {
    @Test
    func `unauthorized is recoverable and auth related`() {
        let error = AbacusUsageError.unauthorized
        #expect(error.isRecoverable == true)
        #expect(error.isAuthRelated == true)
    }

    @Test
    func `sessionExpired is recoverable and auth related`() {
        let error = AbacusUsageError.sessionExpired
        #expect(error.isRecoverable == true)
        #expect(error.isAuthRelated == true)
    }

    @Test
    func `parseFailed is not recoverable`() {
        let error = AbacusUsageError.parseFailed("bad json")
        #expect(error.isRecoverable == false)
        #expect(error.isAuthRelated == false)
        #expect(error.shouldTryNextImportedSession == true)
        #expect(error.shouldClearCachedCookie == true)
    }

    @Test
    func `networkError is not recoverable`() {
        let error = AbacusUsageError.networkError("timeout")
        #expect(error.isRecoverable == false)
        #expect(error.isAuthRelated == false)
        #expect(error.shouldTryNextImportedSession == true)
        #expect(error.shouldClearCachedCookie == false)
    }

    @Test
    func `noSessionCookie is not recoverable`() {
        let error = AbacusUsageError.noSessionCookie
        #expect(error.isRecoverable == false)
        #expect(error.isAuthRelated == false)
        #expect(error.shouldTryNextImportedSession == false)
        #expect(error.shouldClearCachedCookie == false)
    }

    @Test
    func `auth failures continue imported session scanning`() {
        #expect(AbacusUsageError.unauthorized.shouldTryNextImportedSession == true)
        #expect(AbacusUsageError.sessionExpired.shouldTryNextImportedSession == true)
        #expect(AbacusUsageError.unauthorized.shouldClearCachedCookie == true)
        #expect(AbacusUsageError.sessionExpired.shouldClearCachedCookie == true)
    }
}
