import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexWeeklyResetDiagnosticsTests {
    private typealias Reason = CodexWeeklyResetConfirmation.Reason
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let oldBoundary = epoch.addingTimeInterval(500_000)
    private static let newBoundary = oldBoundary.addingTimeInterval(7 * 24 * 60 * 60)
    private static let expiry = newBoundary.addingTimeInterval(24 * 60 * 60)

    @Test
    func `candidate rejection reasons preserve the existing fail closed outcomes`() {
        let cases: [(Reason, (inout Fixture) -> Void)] = [
            (.sourceNotExactOAuth, { $0.source = .init(
                previousIsExactOAuth: false, initialIsExactOAuth: true, confirmationIsExactOAuth: true) }),
            (.missingPreviousSnapshot, { $0.hasPrevious = false }),
            (.confidenceNotExact, { $0.confirmation.confidence = .estimated }),
            (.invalidObservationTime, { $0.observedAt = Date(timeIntervalSince1970: .nan) }),
            (.nonMonotonicObservationTime, { $0.confirmation.updatedAt = $0.initial.updatedAt }),
            (.missingWeeklyWindow, { $0.initial.usedPercent = nil }),
            (.invalidWeeklyUsage, { $0.confirmation.usedPercent = .nan }),
            (.resetThresholdMismatch, { $0.previous.usedPercent = 1 }),
            (.resetThresholdMismatch, { $0.initial.usedPercent = 2 }),
            (.resetThresholdMismatch, { $0.confirmation.usedPercent = 2 }),
            (.invalidResetBoundary, { $0.confirmation.boundary = $0.confirmation.updatedAt }),
            (.inconsistentResetBoundary, { $0.confirmation.boundary = Self.newBoundary.addingTimeInterval(120) }),
            (.unsupportedResetBoundary, {
                $0.initial.boundary = Self.oldBoundary.addingTimeInterval(1)
                $0.confirmation.boundary = $0.initial.boundary
            }),
            (.accountMismatch, { $0.confirmation.email = "other@example.com" }),
            (.planMismatch, { $0.confirmation.plan = "other-plan" }),
            (.missingCreditInventory, { $0.initial.hasCredits = false }),
            (.invalidCreditObservationTime, { $0.initial.creditTime = Date(timeIntervalSince1970: .nan) }),
            (.nonMonotonicCreditObservationTime, { $0.initial.creditTime = Self.epoch.addingTimeInterval(-1) }),
            (.inconsistentAvailableCreditCount, { $0.confirmation.availableCount = 0 }),
            (.inconsistentAvailableCreditCount, { $0.confirmation.availableCount = 2 }),
            (.changedCreditInventory, { $0.confirmation.creditID = "different-credit" }),
            (.changedCreditInventory, { $0.confirmation.creditExpiry = Self.expiry.addingTimeInterval(0.059) }),
        ]
        for (reason, mutate) in cases {
            var fixture = Fixture()
            mutate(&fixture)
            let evaluation = fixture.creation()
            #expect(evaluation.candidate == nil, "Unexpected candidate for \(reason.rawValue)")
            #expect(evaluation.reason == reason)
        }
    }

    @Test
    func `candidate diagnostics report the first failed prerequisite`() {
        var fixture = Fixture()
        fixture.hasPrevious = false
        fixture.source = .init(
            previousIsExactOAuth: true, initialIsExactOAuth: false, confirmationIsExactOAuth: true)
        #expect(fixture.creation().reason == .sourceNotExactOAuth)
        fixture.source = .allExactOAuth
        #expect(fixture.creation().reason == .missingPreviousSnapshot)
        fixture.hasPrevious = true
        fixture.confirmation.email = "other@example.com"
        fixture.confirmation.plan = "other-plan"
        fixture.confirmation.hasCredits = false
        #expect(fixture.creation().reason == .accountMismatch)
        fixture.confirmation.email = fixture.previous.email
        #expect(fixture.creation().reason == .planMismatch)
        fixture.confirmation.plan = fixture.previous.plan
        #expect(fixture.creation().reason == .missingCreditInventory)
    }

    @Test
    func `boundary diagnostic cutoffs keep the existing equivalence rules`() {
        for advance in [0.0, 0.999, 1.0, 119.999, 120.0] {
            var fixture = Fixture()
            fixture.initial.boundary = Self.oldBoundary.addingTimeInterval(advance)
            fixture.confirmation.boundary = fixture.initial.boundary
            let accepted = advance < 1 || advance >= 120
            #expect((fixture.creation().candidate != nil) == accepted)
            #expect(fixture.creation().reason == (accepted ? .candidateCreated : .unsupportedResetBoundary))
        }
        for difference in [119.999, 120.0] {
            var fixture = Fixture()
            fixture.confirmation.boundary = Self.newBoundary.addingTimeInterval(difference)
            #expect(fixture.creation().reason == (difference < 120 ? .candidateCreated : .inconsistentResetBoundary))
        }
    }

    @Test
    func `delayed evaluation explains retention and expiration without changing timing`() throws {
        let fixture = Fixture()
        let creation = fixture.creation()
        let candidate = try #require(creation.candidate)
        #expect(creation.reason == .candidateCreated)
        #expect(candidate.firstObservedAt == fixture.initial.updatedAt)
        #expect(candidate.createdAt == fixture.observedAt)
        let current = Sample(offset: 61, usedPercent: 0.5, boundary: Self.newBoundary)
        let cases: [(TimeInterval, CodexWeeklyResetConfirmation.DelayedCandidateDecision, Reason)] = [
            (-1, .discardCandidate, .futureCandidate),
            (59, .retainCandidate, .minimumDelay),
            (60, .publishCurrent, .confirmedObservation),
            (1800, .publishCurrent, .confirmedObservation),
            (1801, .discardCandidate, .expiredCandidate),
        ]
        for (age, decision, reason) in cases {
            let observedAt = candidate.createdAt.addingTimeInterval(age)
            let evaluation = CodexWeeklyResetConfirmation.evaluateDelayedCandidate(
                previous: fixture.previous.snapshot,
                candidate: candidate,
                current: current.snapshot,
                currentIsExactOAuth: true,
                observedAt: observedAt)
            #expect(evaluation.decision == decision)
            #expect(evaluation.reason == reason)
            let retentionReason = CodexWeeklyResetConfirmation.delayedCandidateRejection(
                candidate, observedAt: observedAt)
            #expect(retentionReason == (decision == .discardCandidate ? reason : nil))
        }
        let stale = CodexWeeklyResetConfirmation.evaluateDelayedCandidate(
            previous: fixture.previous.snapshot,
            candidate: candidate,
            current: candidate.snapshot,
            currentIsExactOAuth: true,
            observedAt: candidate.createdAt.addingTimeInterval(60))
        #expect(stale == .init(decision: .retainCandidate, reason: .staleObservation))
    }

    @Test
    func `delayed evaluation diagnoses incompatible current evidence`() throws {
        let fixture = Fixture()
        let candidate = try #require(fixture.creation().candidate)
        let cases: [(Reason, (inout Sample) -> Void)] = [
            (.confidenceNotExact, { $0.confidence = .unknown }),
            (.invalidObservationTime, { $0.updatedAt = Date(timeIntervalSince1970: .infinity) }),
            (.missingWeeklyWindow, { $0.usedPercent = nil }),
            (.invalidWeeklyUsage, { $0.usedPercent = .nan }),
            (.resetThresholdMismatch, { $0.usedPercent = 2 }),
            (.invalidResetBoundary, { $0.boundary = nil }),
            (.inconsistentResetBoundary, { $0.boundary = Self.newBoundary.addingTimeInterval(120) }),
            (.accountMismatch, { $0.email = "other@example.com" }),
            (.planMismatch, { $0.plan = nil }),
            (.missingCreditInventory, { $0.hasCredits = false }),
            (.changedCreditInventory, { $0.creditID = "different-credit" }),
        ]
        for (reason, mutate) in cases {
            var current = Sample(offset: 61, usedPercent: 0.5, boundary: Self.newBoundary)
            mutate(&current)
            let evaluation = CodexWeeklyResetConfirmation.evaluateDelayedCandidate(
                previous: fixture.previous.snapshot,
                candidate: candidate,
                current: current.snapshot,
                currentIsExactOAuth: true,
                observedAt: candidate.createdAt.addingTimeInterval(60))
            #expect(evaluation == .init(decision: .discardCandidate, reason: reason))
        }
    }

    @Test
    func `candidate version and date validation is shared by pruning and revalidation`() throws {
        let fixture = Fixture()
        let candidate = try #require(fixture.creation().candidate)
        var payload = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])
        payload["evidenceVersion"] = CodexWeeklyResetPublicationCandidate.currentEvidenceVersion + 1
        let unsupported = try JSONDecoder().decode(
            CodexWeeklyResetPublicationCandidate.self, from: JSONSerialization.data(withJSONObject: payload))
        let invalidTime = CodexWeeklyResetPublicationCandidate(
            firstObservedAt: Date(timeIntervalSince1970: .nan),
            createdAt: fixture.observedAt,
            snapshot: fixture.confirmation.snapshot)
        for (invalid, reason) in [
            (unsupported, Reason.evidenceVersionMismatch),
            (invalidTime, .invalidObservationTime),
        ] {
            #expect(CodexWeeklyResetConfirmation.delayedCandidateRejection(
                invalid, observedAt: fixture.observedAt) == reason)
            #expect(CodexWeeklyResetConfirmation.evaluateDelayedCandidate(
                previous: fixture.previous.snapshot,
                candidate: invalid,
                current: fixture.confirmation.snapshot,
                currentIsExactOAuth: true,
                observedAt: fixture.observedAt)
                == .init(decision: .discardCandidate, reason: reason))
        }
    }

    @Test
    func `publication diagnostic metadata adds only the fixed reason code`() {
        let fixture = Fixture()
        let trace = UsageStore.CodexWeeklyResetPublicationTrace(
            previousSnapshot: fixture.previous.snapshot,
            missingWindowBackfillSnapshot: nil,
            publicationBaseline: fixture.previous.snapshot,
            initialSnapshot: fixture.initial.snapshot,
            confirmationSnapshot: fixture.confirmation.snapshot)
        let baseline = UsageStore.codexWeeklyResetPublicationMetadata(
            stage: "candidateCreation", decision: "rejected", trace: trace)
        let diagnosed = UsageStore.codexWeeklyResetPublicationMetadata(
            stage: "candidateCreation", decision: "rejected", reason: .changedCreditInventory, trace: trace)
        #expect(diagnosed == baseline.merging(
            ["reason": "changedCreditInventory"],
            uniquingKeysWith: { _, new in new }))
        let values = diagnosed.values.joined(separator: " ")
        for sensitive in ["sentinel@example.com", "sentinel-workspace", "sentinel-plan", "sentinel-credit"] {
            #expect(!values.contains(sensitive))
        }
        #expect(!values.contains(fixture.previous.snapshot.codexResetCredits?.credits.first?.id ?? "missing-credit"))
    }

    private struct Fixture {
        var previous = Sample(offset: 0, usedPercent: 80, boundary: oldBoundary)
        var initial = Sample(offset: 1, usedPercent: 0, boundary: newBoundary)
        var confirmation = Sample(offset: 2, usedPercent: 0, boundary: newBoundary)
        var source = CodexWeeklyResetConfirmation.SourceEvidence.allExactOAuth
        var hasPrevious = true
        var observedAt = epoch.addingTimeInterval(1)

        func creation() -> CodexWeeklyResetConfirmation.CandidateCreation {
            CodexWeeklyResetConfirmation.evaluateDelayedCandidateCreation(
                previous: self.hasPrevious ? self.previous.snapshot : nil,
                initial: self.initial.snapshot,
                confirmation: self.confirmation.snapshot,
                sourceEvidence: self.source,
                observedAt: self.observedAt)
        }
    }

    private struct Sample {
        var updatedAt: Date
        var usedPercent: Double?
        var boundary: Date?
        var confidence = UsageDataConfidence.exact
        var email: String? = "sentinel@example.com"
        var plan: String? = "sentinel-plan"
        var hasCredits = true
        var creditTime: Date
        var availableCount = 1
        var creditID = "sentinel-credit"
        var creditExpiry = expiry

        init(offset: TimeInterval, usedPercent: Double, boundary: Date) {
            self.updatedAt = epoch.addingTimeInterval(offset)
            self.creditTime = self.updatedAt
            self.usedPercent = usedPercent
            self.boundary = boundary
        }

        var snapshot: UsageSnapshot {
            let credits = CodexRateLimitResetCreditsSnapshot(
                credits: [CodexRateLimitResetCredit(
                    id: self.creditID,
                    resetType: "codex_rate_limits",
                    status: .available,
                    grantedAt: epoch,
                    expiresAt: self.creditExpiry,
                    redeemStartedAt: nil,
                    redeemedAt: nil,
                    title: nil,
                    description: nil)],
                availableCount: self.availableCount,
                updatedAt: self.creditTime)
            return UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: oldBoundary, resetDescription: nil),
                secondary: self.usedPercent.map {
                    RateWindow(usedPercent: $0, windowMinutes: 10080, resetsAt: self.boundary, resetDescription: nil)
                },
                codexResetCredits: self.hasCredits ? credits : nil,
                updatedAt: self.updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: self.email,
                    accountOrganization: "sentinel-workspace",
                    loginMethod: self.plan),
                dataConfidence: self.confidence)
        }
    }
}
