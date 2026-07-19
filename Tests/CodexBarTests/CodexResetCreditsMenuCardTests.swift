import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexResetCreditsMenuCardTests {
    @Test
    func `presentation shows only available inventory in stable expiry order`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let snapshot = Self.snapshot(
            now: now,
            credits: [
                Self.credit(id: "no-expiry", status: .available, now: now, expiresIn: nil),
                Self.credit(id: "late", status: .available, now: now, expiresIn: 172_800),
                Self.credit(id: "redeemed", status: .redeemed, now: now, expiresIn: 43200),
                Self.credit(id: "expired", status: .available, now: now, expiresIn: -1),
                Self.credit(id: "early", status: .available, now: now, expiresIn: 86400),
            ],
            availableCount: 99)

        let model = try Self.model(snapshot: snapshot, now: now)
        let presentation = try #require(model.codexResetCredits)

        #expect(presentation.text == "3 available")
        #expect(presentation.items.map(\.expiryText) == ["Expires in 1d", "Expires in 2d", "No expiry"])
        #expect(presentation.expirySummaryText == "1d · 2d · No expiry")
        #expect(presentation.helpText == "1. Expires in 1d\n2. Expires in 2d\n3. No expiry")
        #expect(presentation.accessibilityLabel.contains(presentation.helpText))
    }

    @Test
    func `no-expiry reset remains visible without a next-expiry date`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let model = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                credits: [Self.credit(id: "no-expiry", status: .available, now: now, expiresIn: nil)]),
            now: now)
        let presentation = try #require(model.codexResetCredits)

        #expect(presentation.text == "1 available")
        #expect(presentation.items.map(\.expiryText) == ["No expiry"])
        #expect(presentation.expirySummaryText == "No expiry")
        #expect(model.hasUsageContent)
    }

    @Test
    func `inventory respects absolute reset-time style`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let expiresAt = now.addingTimeInterval(86400)
        let model = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                credits: [Self.credit(id: "finite", status: .available, now: now, expiresIn: 86400)]),
            resetStyle: .absolute,
            now: now)
        let presentation = try #require(model.codexResetCredits)
        let formatted = UsageFormatter.resetDescription(from: expiresAt, now: now)

        #expect(presentation.items.map(\.expiryText) == ["Expires \(formatted)"])
        #expect(presentation.expirySummaryText == formatted)
    }

    @Test
    func `optional usage preference does not hide reset inventory`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let model = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                credits: [Self.credit(id: "finite", status: .available, now: now, expiresIn: 86400)]),
            showOptionalUsage: false,
            now: now)

        #expect(model.codexResetCredits?.text == "1 available")
        #expect(model.codexResetCredits?.expirySummaryText == "1d")
    }

    @Test
    func `compact expiry summary caps visible dates`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let credits = (1...6).map { day in
            Self.credit(id: "day-\(day)", status: .available, now: now, expiresIn: Double(day * 86400))
        }
        let model = try Self.model(snapshot: Self.snapshot(now: now, credits: credits), now: now)

        let presentation = try #require(model.codexResetCredits)
        #expect(presentation.expirySummaryText == "1d · 2d · 3d · 4d · +2")
        #expect(presentation.helpText.split(separator: "\n").count == 6)
    }

    @Test
    func `hosted usage model keeps reset inventory compatible with live refresh`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let model = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                credits: [Self.credit(id: "finite", status: .available, now: now, expiresIn: 86400)]),
            now: now)

        #expect(model.codexResetCredits != nil)
        #expect(model.hasCompatibleTrackedLayout(with: model))
    }

    @Test
    func `empty filtered inventory does not create hosted reset rows`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let model = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                credits: [Self.credit(id: "expired", status: .available, now: now, expiresIn: -1)],
                availableCount: 1),
            now: now)

        #expect(model.codexResetCredits == nil)
        #expect(model.hasCompatibleTrackedLayout(with: model))
    }

    private static func model(
        snapshot: UsageSnapshot,
        showOptionalUsage: Bool = true,
        resetStyle: ResetTimeDisplayStyle = .countdown,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        return UsageMenuCardView.Model.make(UsageMenuCardView.Model.Input(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: resetStyle,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptionalUsage,
            hidePersonalInfo: false,
            now: now))
    }

    private static func snapshot(
        now: Date,
        credits: [CodexRateLimitResetCredit],
        availableCount: Int? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            codexResetCredits: CodexRateLimitResetCreditsSnapshot(
                credits: credits,
                availableCount: availableCount ?? credits.count,
                updatedAt: now),
            updatedAt: now)
    }

    private static func credit(
        id: String,
        status: CodexRateLimitResetCreditStatus,
        now: Date,
        expiresIn: TimeInterval?) -> CodexRateLimitResetCredit
    {
        CodexRateLimitResetCredit(
            id: id,
            resetType: "codex_rate_limits",
            status: status,
            grantedAt: now.addingTimeInterval(-3600),
            expiresAt: expiresIn.map(now.addingTimeInterval),
            redeemStartedAt: nil,
            redeemedAt: nil,
            title: nil,
            description: nil)
    }
}
