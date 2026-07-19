import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite("Codex session restore notifications")
struct CodexSessionQuotaFalseRestoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `same future boundary suppresses restore and duplicate depletion`() throws {
        let owner = try self.owner("same-boundary")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 0, boundary: boundary, at: self.start.addingTimeInterval(120), owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(180), owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
    }

    @Test
    func `advanced boundary before trusted expiry stays suppressed`() throws {
        let owner = try self.owner("early-advanced")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let advanced = boundary.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 0, boundary: advanced, at: self.start.addingTimeInterval(120), owner: owner)
        self.observe(store, used: 10, boundary: advanced, at: self.start.addingTimeInterval(180), owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)
    }

    @Test
    func `depleted boundary stays frozen until its reset can be proven`() throws {
        let owner = try self.owner("depleted-advanced")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let advanced = boundary.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 100, boundary: advanced, at: self.start.addingTimeInterval(120), owner: owner)
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)
        self.observe(store, used: 100, boundary: advanced, at: boundary.addingTimeInterval(60), owner: owner)
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)
        self.observe(store, used: 0, boundary: advanced, at: boundary.addingTimeInterval(120), owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == advanced)
    }

    @Test
    func `depleted observation recovers a missing trusted boundary`() throws {
        let owner = try self.owner("depleted-recovered-boundary")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: nil, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(120), owner: owner)
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)

        self.observe(store, used: 20, boundary: boundary, at: self.start.addingTimeInterval(180), owner: owner)
        self.observe(store, used: 10, boundary: boundary, at: self.start.addingTimeInterval(240), owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt == nil)
    }

    @Test
    func `expired baseline boundary cannot produce a single sample restore`() throws {
        let owner = try self.owner("expired-baseline")
        let expired = self.start.addingTimeInterval(-60)
        let future = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 100, boundary: expired, at: self.start, owner: owner)
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == nil)

        let firstPositive = self.start.addingTimeInterval(60)
        self.observe(store, used: 20, boundary: future, at: firstPositive, owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt == firstPositive)

        self.observe(store, used: 10, boundary: future, at: self.start.addingTimeInterval(120), owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == future)
    }

    @Test
    func `boundary expired before evaluation is not trusted`() throws {
        let owner = try self.owner("expired-before-evaluation")
        let observedAt = self.start.addingTimeInterval(60)
        let boundary = self.start.addingTimeInterval(120)
        let evaluatedAt = self.start.addingTimeInterval(180)
        let store = Self.makeStore(notifier: SessionQuotaNotifierSpy())

        self.observe(
            store,
            used: 100,
            boundary: boundary,
            at: observedAt,
            evaluatedAt: evaluatedAt,
            owner: owner)

        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == nil)
    }

    @Test
    func `depletion cannot advance a still future trusted boundary`() throws {
        let owner = try self.owner("depletion-advanced")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let advanced = boundary.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: advanced, at: self.start.addingTimeInterval(60), owner: owner)
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)

        self.observe(store, used: 20, boundary: advanced, at: boundary.addingTimeInterval(60), owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == advanced)
    }

    @Test
    func `pre boundary observation cannot advance metadata when processed later`() throws {
        let owner = try self.owner("delayed-observation")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let advanced = boundary.addingTimeInterval(5 * 3600)
        let store = Self.makeStore(notifier: SessionQuotaNotifierSpy())

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(
            store,
            used: 30,
            boundary: advanced,
            at: self.start.addingTimeInterval(60),
            evaluatedAt: boundary.addingTimeInterval(60),
            owner: owner)

        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)
    }

    @Test(arguments: [false, true])
    func `ambiguous post expiry restore requires two fresh observations`(boundaryPresent: Bool) throws {
        let owner = try self.owner(boundaryPresent ? "expired-equivalent" : "expired-missing")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        let first = boundary.addingTimeInterval(60)
        self.observe(store, used: 20, boundary: boundaryPresent ? boundary : nil, at: first, owner: owner)
        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt == first)

        self.observe(
            store,
            used: 10,
            boundary: boundaryPresent ? boundary : nil,
            at: boundary.addingTimeInterval(120),
            owner: owner)
        self.observe(
            store,
            used: 5,
            boundary: boundaryPresent ? boundary : nil,
            at: boundary.addingTimeInterval(180),
            owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `boundaryless restore requires two fresh observations`() throws {
        let owner = try self.owner("boundaryless")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: nil, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 20, boundary: nil, at: self.start.addingTimeInterval(120), owner: owner)
        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt != nil)

        self.observe(store, used: 10, boundary: nil, at: self.start.addingTimeInterval(180), owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `advanced post expiry boundary restores exactly once`() throws {
        let owner = try self.owner("post-expiry-advanced")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let advanced = boundary.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 20, boundary: advanced, at: boundary.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 10, boundary: advanced, at: boundary.addingTimeInterval(120), owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == advanced)
    }

    @Test
    func `advanced boundary expired at observation time requires confirmation`() throws {
        let owner = try self.owner("advanced-expired-at-observation")
        let boundary = self.start.addingTimeInterval(100)
        let candidate = self.start.addingTimeInterval(250)
        let previous = SessionQuotaTransitionState(
            remaining: 0,
            source: .primary,
            observedAt: self.start,
            codexOwnerKey: owner,
            trustedResetBoundary: boundary,
            pendingCodexRestoreObservationAt: nil)

        let evaluation = SessionQuotaTransitionReducer.evaluate(
            previous: previous,
            observation: SessionQuotaTransitionObservation(
                provider: .codex,
                remaining: 80,
                source: .primary,
                resetBoundary: candidate,
                observedAt: self.start.addingTimeInterval(300),
                evaluationTime: self.start.addingTimeInterval(200),
                codexOwnerKey: owner),
            notificationsEnabled: true)

        #expect(evaluation.outcome == .awaitingCodexRestoreConfirmation)
        #expect(evaluation.state.trustedResetBoundary == boundary)
    }

    @Test
    func `regressed post expiry boundary requires two fresh observations`() throws {
        let owner = try self.owner("regressed")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let regressed = self.start.addingTimeInterval(10 * 60)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 20, boundary: regressed, at: boundary.addingTimeInterval(60), owner: owner)
        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt != nil)

        self.observe(store, used: 10, boundary: regressed, at: boundary.addingTimeInterval(120), owner: owner)
        self.observe(store, used: 5, boundary: regressed, at: boundary.addingTimeInterval(180), owner: owner)

        #expect(notifier.transitions == [.depleted, .restored])
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt == nil)
    }

    @Test
    func `older and equal observations cannot change the depleted baseline`() throws {
        let owner = try self.owner("observation-order")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        let depletedAt = self.start.addingTimeInterval(120)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: depletedAt, owner: owner)
        self.observe(store, used: 0, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 0, boundary: boundary, at: depletedAt, owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(store.sessionQuotaTransitionStates[.codex]?.observedAt == depletedAt)
    }

    @Test
    func `owner change establishes a new baseline without restoring`() throws {
        let ownerA = try self.owner("owner-a")
        let ownerB = try self.owner("owner-b")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: ownerA)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: ownerA)
        self.observe(store, used: 0, boundary: boundary, at: self.start.addingTimeInterval(120), owner: ownerB)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.codexOwnerKey == ownerB)
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 100)
    }

    @Test
    func `source change establishes a new reducer baseline`() throws {
        let owner = try self.owner("source-change")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let previous = SessionQuotaTransitionState(
            remaining: 0,
            source: .primary,
            observedAt: self.start,
            codexOwnerKey: owner,
            trustedResetBoundary: boundary,
            pendingCodexRestoreObservationAt: nil)

        let evaluation = SessionQuotaTransitionReducer.evaluate(
            previous: previous,
            observation: SessionQuotaTransitionObservation(
                provider: .codex,
                remaining: 100,
                source: .copilotSecondaryFallback,
                resetBoundary: boundary,
                observedAt: self.start.addingTimeInterval(60),
                evaluationTime: self.start.addingTimeInterval(60),
                codexOwnerKey: owner),
            notificationsEnabled: true)

        #expect(evaluation.outcome == .baselineChanged)
        #expect(evaluation.state.remaining == 100)
        #expect(evaluation.state.source == .copilotSecondaryFallback)
    }

    @Test
    func `missing owner fails closed and clears prior state`() throws {
        let owner = try self.owner("missing-owner")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: boundary, updatedAt: self.start.addingTimeInterval(60)),
            codexOwnerKey: nil,
            now: self.start.addingTimeInterval(60))

        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)
        #expect(notifier.transitions.isEmpty)

        self.observe(
            store,
            used: 100,
            boundary: boundary,
            at: self.start.addingTimeInterval(120),
            owner: owner)

        #expect(notifier.transitions.isEmpty)
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(!store.codexSessionQuotaBaselineRequired)
    }
}

extension CodexSessionQuotaFalseRestoreTests {
    @Test
    func `missing owner keeps stale observations behind the fresh baseline barrier`() throws {
        let owner = try self.owner("missing-owner-watermark")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        let invalidatedAt = self.start.addingTimeInterval(120)

        self.observe(store, used: 20, boundary: nil, at: self.start, owner: owner)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: self.snapshot(used: 100, resetBoundary: nil, updatedAt: invalidatedAt),
            codexOwnerKey: nil,
            now: invalidatedAt)

        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 20, boundary: nil, at: self.start.addingTimeInterval(90), owner: owner)
        self.observe(store, used: 10, boundary: nil, at: self.start.addingTimeInterval(100), owner: owner)

        #expect(notifier.transitions.isEmpty)
        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequirement?.observedAtWatermark == invalidatedAt)

        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(121), owner: owner)

        #expect(notifier.transitions.isEmpty)
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(!store.codexSessionQuotaBaselineRequired)
    }

    @Test
    func `windowless Codex result advances a matching depleted baseline watermark`() throws {
        let owner = try self.owner("windowless-partial")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: self.start.addingTimeInterval(120),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "session-fixture@example.test",
                    accountOrganization: nil,
                    loginMethod: "test")),
            codexOwnerKey: owner,
            now: self.start.addingTimeInterval(120))

        self.observe(store, used: 20, boundary: boundary, at: self.start.addingTimeInterval(90), owner: owner)
        self.observe(store, used: 10, boundary: boundary, at: self.start.addingTimeInterval(100), owner: owner)

        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(store.sessionQuotaTransitionStates[.codex]?.observedAt == self.start.addingTimeInterval(120))
        #expect(store.sessionQuotaTransitionStates[.codex]?.trustedResetBoundary == boundary)
        #expect(notifier.transitions == [.depleted])

        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(180), owner: owner)

        #expect(notifier.transitions == [.depleted])
    }

    @Test
    func `windowless Codex result blocks stale boundaryless restore confirmation`() throws {
        let owner = try self.owner("windowless-boundaryless")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: nil, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: owner)
        store.handleSessionQuotaTransition(
            provider: .codex,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: self.start.addingTimeInterval(120),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "session-fixture@example.test",
                    accountOrganization: nil,
                    loginMethod: "test")),
            codexOwnerKey: owner,
            now: self.start.addingTimeInterval(120))

        self.observe(store, used: 20, boundary: nil, at: self.start.addingTimeInterval(90), owner: owner)
        self.observe(store, used: 10, boundary: nil, at: self.start.addingTimeInterval(100), owner: owner)

        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(store.sessionQuotaTransitionStates[.codex]?.observedAt == self.start.addingTimeInterval(120))
        #expect(store.sessionQuotaTransitionStates[.codex]?.pendingCodexRestoreObservationAt == nil)
        #expect(notifier.transitions == [.depleted])

        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(180), owner: owner)

        #expect(notifier.transitions == [.depleted])
    }

    @Test
    func `disabled provider cleanup does not refire Codex depletion`() throws {
        let owner = try self.owner("disabled-provider-cleanup")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        store.clearDisabledProviderState(enabledProviders: [])

        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)

        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(120), owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(!store.codexSessionQuotaBaselineRequired)
    }

    @Test
    func `unavailable provider cleanup does not refire Codex depletion`() throws {
        let owner = try self.owner("unavailable-provider-cleanup")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(60), owner: owner)
        store.clearUnavailableProviderState(
            displayEnabledProviders: [.codex],
            availableProviders: [])

        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)

        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(120), owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(!store.codexSessionQuotaBaselineRequired)
    }

    @Test
    func `cleanup after a positive Codex baseline still reports depletion on recovery`() throws {
        let owner = try self.owner("positive-provider-cleanup")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        store.clearDisabledProviderState(enabledProviders: [])

        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(!store.codexSessionQuotaBaselineRequired)

        self.observe(store, used: 100, boundary: boundary, at: self.start.addingTimeInterval(120), owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
    }

    @Test
    func `cleanup without a prior Codex baseline keeps startup depletion semantics`() throws {
        let owner = try self.owner("startup-cleanup")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        store.clearDisabledProviderState(enabledProviders: [])

        #expect(!store.codexSessionQuotaBaselineRequired)

        self.observe(store, used: 100, boundary: nil, at: self.start, owner: owner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
    }

    @Test
    func `notifications disabled keep stale observations behind the fresh baseline barrier`() throws {
        let owner = try self.owner("disabled-watermark")
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        let invalidatedAt = self.start.addingTimeInterval(120)

        self.observe(store, used: 20, boundary: nil, at: self.start, owner: owner)
        store.settings.sessionQuotaNotificationsEnabled = false
        self.observe(store, used: 100, boundary: nil, at: invalidatedAt, owner: owner)

        #expect(notifier.transitions.isEmpty)
        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)
        #expect(store.codexSessionQuotaBaselineRequirement?.observedAtWatermark == invalidatedAt)

        store.settings.sessionQuotaNotificationsEnabled = true
        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: owner)
        self.observe(store, used: 20, boundary: nil, at: self.start.addingTimeInterval(90), owner: owner)
        self.observe(store, used: 10, boundary: nil, at: self.start.addingTimeInterval(100), owner: owner)
        self.observe(store, used: 20, boundary: nil, at: invalidatedAt, owner: owner)

        #expect(notifier.transitions.isEmpty)
        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequirement?.observedAtWatermark == invalidatedAt)

        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(121), owner: owner)

        #expect(notifier.transitions.isEmpty)
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(!store.codexSessionQuotaBaselineRequired)

        self.observe(store, used: 20, boundary: nil, at: self.start.addingTimeInterval(122), owner: owner)
        self.observe(store, used: 10, boundary: nil, at: self.start.addingTimeInterval(123), owner: owner)

        #expect(notifier.transitions == [.restored])

        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(124), owner: owner)

        #expect(notifier.transitions == [.restored, .depleted])
    }

    @Test
    func `non Codex providers preserve immediate restore semantics`() {
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, provider: .claude, used: 20, boundary: boundary, at: self.start, owner: nil)
        self.observe(
            store,
            provider: .claude,
            used: 100,
            boundary: boundary,
            at: self.start.addingTimeInterval(60),
            owner: nil)
        self.observe(
            store,
            provider: .claude,
            used: 0,
            boundary: boundary,
            at: self.start.addingTimeInterval(120),
            owner: nil)

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `non Codex providers preserve disabled baseline tracking`() {
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        store.settings.sessionQuotaNotificationsEnabled = false

        self.observe(store, provider: .claude, used: 20, boundary: nil, at: self.start, owner: nil)
        self.observe(
            store,
            provider: .claude,
            used: 100,
            boundary: nil,
            at: self.start.addingTimeInterval(60),
            owner: nil)
        #expect(notifier.transitions.isEmpty)

        store.settings.sessionQuotaNotificationsEnabled = true
        self.observe(
            store,
            provider: .claude,
            used: 20,
            boundary: nil,
            at: self.start.addingTimeInterval(120),
            owner: nil)
        #expect(notifier.transitions == [.restored])
    }

    @Test
    func `selected Codex account caller forwards its stable owner`() async throws {
        let expectedOwner = try self.owner("selected-caller")
        let limitResetOwner = try #require(CodexLimitResetOwnerKey(
            identity: .providerAccount(id: "workspace-fixture-selected-caller"),
            accountEmail: "session-fixture@example.test"))
        let now = self.start
        let snapshot = self.snapshot(
            used: 20,
            resetBoundary: now.addingTimeInterval(5 * 3600),
            updatedAt: now)
        let account = CodexVisibleAccount(
            id: "live:selected-caller",
            email: "session-fixture@example.test",
            workspaceAccountID: "workspace-fixture-selected-caller",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let result = ProviderFetchResult(
            usage: snapshot,
            credits: nil,
            dashboard: nil,
            sourceLabel: "fixture",
            strategyID: "fixture.oauth",
            strategyKind: .oauth)
        let store = Self.makeStore(notifier: SessionQuotaNotifierSpy())

        await store.applySelectedCodexVisibleAccountOutcome(
            ProviderFetchOutcome(result: .success(result), attempts: []),
            account: account,
            snapshot: snapshot,
            sourceLabel: "fixture",
            limitResetOwnerKey: limitResetOwner)

        #expect(store.sessionQuotaTransitionStates[.codex]?.codexOwnerKey == expectedOwner)
    }

    @Test
    func `selected Codex accounts keep independent quota warning episodes`() async throws {
        let managedAccountID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let firstAccount = CodexVisibleAccount(
            id: "live:first-quota-account",
            email: "first-quota@example.test",
            workspaceAccountID: "workspace-first-quota-account",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let secondAccount = CodexVisibleAccount(
            id: "managed:\(managedAccountID.uuidString.lowercased())",
            email: "second-quota@example.test",
            workspaceAccountID: "workspace-second-quota-account",
            storedAccountID: managedAccountID,
            selectionSource: .managedAccount(id: managedAccountID),
            isActive: false,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        let isolatedCodexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionQuotaFalseRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedCodexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedCodexHome) }
        store.settings._test_codexReconciliationEnvironment = ["CODEX_HOME": isolatedCodexHome.path]
        defer { store.settings._test_codexReconciliationEnvironment = nil }
        store.settings.sessionQuotaNotificationsEnabled = false
        store.settings.quotaWarningNotificationsEnabled = true
        store.settings.quotaWarningThresholds = [50]
        store.settings.setQuotaWarningWindowEnabled(.session, enabled: true)
        store.settings.setQuotaWarningWindowEnabled(.weekly, enabled: false)

        for (account, usedPercent) in [
            (firstAccount, 40.0),
            (secondAccount, 40.0),
            (firstAccount, 55.0),
            (secondAccount, 30.0),
            (firstAccount, 55.0),
            (secondAccount, 55.0),
        ] {
            let snapshot = self.snapshot(
                used: usedPercent,
                resetBoundary: nil,
                updatedAt: self.start,
                email: account.email)
            let result = ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture.oauth",
                strategyKind: .oauth)
            await store.applySelectedCodexVisibleAccountOutcome(
                ProviderFetchOutcome(result: .success(result), attempts: []),
                account: account,
                snapshot: snapshot,
                sourceLabel: "fixture",
                limitResetOwnerKey: nil)
        }

        #expect(notifier.quotaWarningPosts.map(\.accountDisplayName) == [
            "first-quota@example.test",
            "second-quota@example.test",
        ])
        #expect(notifier.quotaWarningPosts.allSatisfy { $0.threshold == 50 })
    }

    @Test
    func `selected email only Codex account keeps session notifications`() async {
        let email = "email-only-session@example.test"
        let account = CodexVisibleAccount(
            id: "live:email-only-session",
            email: email,
            workspaceAccountID: nil,
            authFingerprint: "fixture-auth-fingerprint",
            storedAccountID: nil,
            selectionSource: .liveSystem,
            isActive: true,
            isLive: true,
            canReauthenticate: false,
            canRemove: false)
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)
        let boundary = self.start.addingTimeInterval(5 * 3600)

        let advancedBoundary = boundary.addingTimeInterval(5 * 3600)
        for (used, observedAt, resetBoundary) in [
            (20.0, self.start, boundary),
            (100.0, self.start.addingTimeInterval(60), boundary),
            (20.0, boundary.addingTimeInterval(60), advancedBoundary),
            (10.0, boundary.addingTimeInterval(120), advancedBoundary),
        ] {
            let snapshot = self.snapshot(
                used: used,
                resetBoundary: resetBoundary,
                updatedAt: observedAt,
                email: email)
            let result = ProviderFetchResult(
                usage: snapshot,
                credits: nil,
                dashboard: nil,
                sourceLabel: "fixture",
                strategyID: "fixture.oauth",
                strategyKind: .oauth)
            await store.applySelectedCodexVisibleAccountOutcome(
                ProviderFetchOutcome(result: .success(result), attempts: []),
                account: account,
                snapshot: snapshot,
                sourceLabel: "fixture",
                limitResetOwnerKey: nil)
        }

        #expect(store.sessionQuotaTransitionStates[.codex]?.codexOwnerKey != nil)
        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `email only notification owners isolate source and credential rotation`() throws {
        let email = "email-only-owner@example.test"
        let identity = CodexIdentity.emailOnly(normalizedEmail: email)
        let liveA = try #require(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-a")))
        let liveB = try #require(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-b")))
        let profile = try #require(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .profileHome(path: "/tmp/codex-email-only-owner"),
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-a")))
        let providerIdentity = CodexIdentity.providerAccount(id: "workspace-email-only-owner")
        let providerA = try #require(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: providerIdentity,
            accountKey: email,
            authFingerprint: "fixture-a")))
        let providerB = try #require(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .profileHome(path: "/tmp/codex-email-only-owner"),
            identity: providerIdentity,
            accountKey: email,
            authFingerprint: "fixture-b")))

        #expect(liveA != liveB)
        #expect(liveA != profile)
        #expect(providerA == providerB)
        #expect(CodexLimitResetOwnerKey(identity: identity, accountEmail: email) == nil)
        #expect(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email,
            authFingerprint: nil)) == nil)
    }

    @Test
    func `email only credential rotation establishes a new baseline`() throws {
        let email = "rotating-email-only-owner@example.test"
        let identity = CodexIdentity.emailOnly(normalizedEmail: email)
        let oldGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-old")
        let newGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-new")
        let oldOwner = try #require(UsageStore.codexSessionQuotaOwnerKey(for: oldGuard))
        let newOwner = try #require(UsageStore.codexSessionQuotaOwnerKey(for: newGuard))
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        self.observe(store, used: 20, boundary: nil, at: self.start, owner: oldOwner)
        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: oldOwner)
        store.snapshots[.codex] = self.snapshot(
            used: 100,
            resetBoundary: nil,
            updatedAt: self.start.addingTimeInterval(60),
            email: email)
        store.lastCodexUsagePublicationGuard = oldGuard
        store.lastCodexAccountScopedRefreshGuard = oldGuard

        store.reconcileCodexAccountStateForUsageOwner(newGuard)

        #expect(store.snapshots[.codex] == nil)
        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)
        self.observe(
            store,
            used: 100,
            boundary: nil,
            at: self.start.addingTimeInterval(120),
            owner: newOwner)

        #expect(notifier.transitions == [.depleted])
        #expect(store.sessionQuotaTransitionStates[.codex]?.codexOwnerKey == newOwner)
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        #expect(!store.codexSessionQuotaBaselineRequired)

        self.observe(
            store,
            used: 20,
            boundary: nil,
            at: self.start.addingTimeInterval(180),
            owner: newOwner)
        self.observe(
            store,
            used: 10,
            boundary: nil,
            at: self.start.addingTimeInterval(240),
            owner: newOwner)

        #expect(notifier.transitions == [.depleted, .restored])
    }

    @Test
    func `provider owner survives source and credential changes`() throws {
        let email = "provider-source-owner@example.test"
        let identity = CodexIdentity.providerAccount(id: "workspace-provider-source-owner")
        let oldGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-old")
        let newGuard = CodexAccountScopedRefreshGuard(
            source: .profileHome(path: "/tmp/codex-provider-source-owner"),
            identity: identity,
            accountKey: email,
            authFingerprint: "fixture-new")
        let oldOwner = try #require(UsageStore.codexSessionQuotaOwnerKey(for: oldGuard))
        let newOwner = try #require(UsageStore.codexSessionQuotaOwnerKey(for: newGuard))
        let notifier = SessionQuotaNotifierSpy()
        let store = Self.makeStore(notifier: notifier)

        #expect(oldOwner == newOwner)
        self.observe(store, used: 20, boundary: nil, at: self.start, owner: oldOwner)
        self.observe(store, used: 100, boundary: nil, at: self.start.addingTimeInterval(60), owner: oldOwner)
        store.snapshots[.codex] = self.snapshot(
            used: 100,
            resetBoundary: nil,
            updatedAt: self.start.addingTimeInterval(60),
            email: email)
        store.lastCodexUsagePublicationGuard = oldGuard
        store.lastCodexAccountScopedRefreshGuard = oldGuard

        store.reconcileCodexAccountStateForUsageOwner(newGuard)

        #expect(store.snapshots[.codex] == nil)
        #expect(store.sessionQuotaTransitionStates[.codex]?.remaining == 0)
        self.observe(
            store,
            used: 20,
            boundary: nil,
            at: self.start.addingTimeInterval(120),
            owner: newOwner)
        self.observe(
            store,
            used: 10,
            boundary: nil,
            at: self.start.addingTimeInterval(180),
            owner: newOwner)

        #expect(notifier.transitions == [.depleted, .restored])
        _ = store.prepareCodexAccountScopedRefreshIfNeeded(
            forceInvalidation: true,
            currentGuardOverride: newGuard)
        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)
    }

    @Test
    func `regular refresh owner builder supports email only identity`() throws {
        let email = "regular-email-only-owner@example.test"
        let refreshGuard = CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .emailOnly(normalizedEmail: email),
            accountKey: email,
            authFingerprint: "fixture-regular")
        let owner = try #require(UsageStore.codexSessionQuotaOwnerKey(for: refreshGuard))

        #expect(!owner.rawValue.isEmpty)
    }

    @Test
    func `clearing published Codex usage clears typed transition state`() throws {
        let owner = try self.owner("cleanup")
        let boundary = self.start.addingTimeInterval(5 * 3600)
        let store = Self.makeStore(notifier: SessionQuotaNotifierSpy())

        self.observe(store, used: 20, boundary: boundary, at: self.start, owner: owner)
        #expect(store.sessionQuotaTransitionStates[.codex] != nil)

        store.clearCodexPublishedUsageState()

        #expect(store.sessionQuotaTransitionStates[.codex] == nil)
        #expect(store.codexSessionQuotaBaselineRequired)
    }

    private func observe(
        _ store: UsageStore,
        provider: UsageProvider = .codex,
        used: Double,
        boundary: Date?,
        at: Date,
        evaluatedAt: Date? = nil,
        owner: CodexSessionQuotaOwnerKey?)
    {
        store.handleSessionQuotaTransition(
            provider: provider,
            snapshot: self.snapshot(
                provider: provider,
                used: used,
                resetBoundary: boundary,
                updatedAt: at),
            codexOwnerKey: owner,
            now: evaluatedAt ?? at)
    }

    private func snapshot(
        provider: UsageProvider = .codex,
        used: Double,
        resetBoundary: Date?,
        updatedAt: Date,
        email: String = "session-fixture@example.test") -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: used,
                windowMinutes: 300,
                resetsAt: resetBoundary,
                resetDescription: nil),
            secondary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "test"))
    }

    private func owner(_ suffix: String) throws -> CodexSessionQuotaOwnerKey {
        try #require(CodexSessionQuotaOwnerKey(refreshGuard: CodexAccountScopedRefreshGuard(
            source: .liveSystem,
            identity: .providerAccount(id: "workspace-fixture-\(suffix)"),
            accountKey: "session-fixture@example.test")))
    }

    private static func makeStore(notifier: SessionQuotaNotifierSpy) -> UsageStore {
        let suiteName = "CodexSessionQuotaFalseRestoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
    }
}

@MainActor
private final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
    private(set) var transitions: [SessionQuotaTransition] = []
    private(set) var quotaWarningPosts: [QuotaWarningEvent] = []

    func post(transition: SessionQuotaTransition, provider _: UsageProvider, badge _: NSNumber?) {
        self.transitions.append(transition)
    }

    func postQuotaWarning(
        event: QuotaWarningEvent,
        provider _: UsageProvider,
        soundEnabled _: Bool,
        onScreenAlertEnabled _: Bool)
    {
        self.quotaWarningPosts.append(event)
    }
}
