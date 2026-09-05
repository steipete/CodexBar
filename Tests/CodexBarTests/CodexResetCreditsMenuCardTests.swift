import AppKit
import CodexBarCore
import Foundation
import SwiftUI
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
    func `changing reset credit countdown keeps hosted layout compatible`() throws {
        let (current, candidate) = try Self.weeklyResetTransitionModels()

        #expect(current.codexResetCredits?.expirySummaryText == "1d 6h")
        #expect(candidate.codexResetCredits?.expirySummaryText == "18h")
        #expect(current.codexResetCredits != candidate.codexResetCredits)
        #expect(current.hasCompatibleTrackedLayout(with: candidate))
    }

    @Test
    func `metric metadata may disappear but cannot appear in frozen tracked layout`() throws {
        let (withMetadata, withoutMetadata) = try Self.weeklyResetTransitionModels()
        let currentWeekly = try #require(withMetadata.metrics.first { $0.id == "secondary" })
        let candidateWeekly = try #require(withoutMetadata.metrics.first { $0.id == "secondary" })

        #expect(currentWeekly.linePresentation(title: currentWeekly.title).metaText != nil)
        #expect(candidateWeekly.linePresentation(title: candidateWeekly.title).metaText == nil)
        #expect(withMetadata.hasCompatibleTrackedLayout(with: withoutMetadata))
        #expect(!withoutMetadata.hasCompatibleTrackedLayout(with: withMetadata))
    }

    @MainActor
    @Test
    func `tracked refresh rejects a different account even while personal information is hidden`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let snapshot = Self.snapshot(
            now: now,
            credits: [Self.credit(id: "finite", status: .available, now: now, expiresIn: 86400)])
        let frozen = try Self.model(
            snapshot: snapshot,
            email: "first@example.com",
            hidePersonalInfo: true,
            now: now)
        let switched = try Self.model(
            snapshot: snapshot,
            email: "second@example.com",
            hidePersonalInfo: true,
            now: now)
        let sameAccount = try Self.model(
            snapshot: snapshot,
            email: " FIRST@EXAMPLE.COM ",
            hidePersonalInfo: true,
            now: now)
        let firstWorkspace = try Self.model(
            snapshot: snapshot,
            email: "shared@example.com",
            accountID: "first-workspace",
            hidePersonalInfo: true,
            now: now)
        let secondWorkspace = try Self.model(
            snapshot: snapshot,
            email: "shared@example.com",
            accountID: "second-workspace",
            hidePersonalInfo: true,
            now: now)

        #expect(frozen.email == switched.email)
        #expect(frozen.accountIdentityFingerprint != switched.accountIdentityFingerprint)
        #expect(frozen.accountIdentityFingerprint == sameAccount.accountIdentityFingerprint)
        #expect(firstWorkspace.accountIdentityFingerprint != secondWorkspace.accountIdentityFingerprint)
        #expect(!frozen.hasCompatibleTrackedLayout(with: switched))
        #expect(!switched.hasCompatibleTrackedLayout(with: frozen))
        #expect(!firstWorkspace.hasCompatibleTrackedLayout(with: secondWorkspace))
        #expect(frozen.hasCompatibleTrackedLayout(with: sameAccount))

        let monitor = MenuCardRefreshMonitor(
            resolveModel: { _ in switched },
            isProviderRefreshActive: { _ in false })
        monitor.beginManualRefresh(frozenModels: [.codex: frozen], provider: .codex)
        #expect(!monitor.publishResolvedModelIfCompatible(for: .codex))
        #expect(monitor.model(for: .codex, fallback: frozen).accountIdentityFingerprint
            == frozen.accountIdentityFingerprint)
    }

    @MainActor
    @Test
    func `refresh monitor publishes reset usage when reset credit countdown changes`() throws {
        let (frozen, resolved) = try Self.weeklyResetTransitionModels()
        let frozenResetText = try #require(frozen.metrics.first { $0.id == "secondary" }?.resetText)
        let resolvedResetText = try #require(resolved.metrics.first { $0.id == "secondary" }?.resetText)
        let monitor = MenuCardRefreshMonitor(
            resolveModel: { _ in resolved },
            isProviderRefreshActive: { _ in false })
        monitor.beginManualRefresh(frozenModels: [.codex: frozen], provider: .codex)

        #expect(resolvedResetText.count > frozenResetText.count)
        #expect(monitor.publishResolvedModelIfCompatible(for: .codex))
        let visible = monitor.model(for: .codex, fallback: frozen)
        #expect(visible.metrics.map(\.percent) == resolved.metrics.map(\.percent))
        #expect(visible.metrics.map(\.percent) != frozen.metrics.map(\.percent))
        #expect(visible.codexResetCredits == resolved.codexResetCredits)

        let width: CGFloat = 320
        let constraint = CGSize(width: width, height: .greatestFiniteMagnitude)
        let frozenSize = NSHostingController(rootView: UsageMenuCardUsageSectionView(
            model: frozen,
            layoutModel: frozen,
            showBottomDivider: false,
            bottomPadding: 6,
            width: width)).sizeThatFits(in: constraint)
        let resolvedSize = NSHostingController(rootView: UsageMenuCardUsageSectionView(
            model: resolved,
            layoutModel: frozen,
            showBottomDivider: false,
            bottomPadding: 6,
            width: width)).sizeThatFits(in: constraint)
        #expect(abs(resolvedSize.height - frozenSize.height) < 0.5)
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

    @Test
    func `adding or removing reset inventory requires hosted layout rebuild`() throws {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let withInventory = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                credits: [Self.credit(id: "finite", status: .available, now: now, expiresIn: 86400)]),
            now: now)
        let withoutInventory = try Self.model(
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            now: now)

        #expect(!withInventory.hasCompatibleTrackedLayout(with: withoutInventory))
        #expect(!withoutInventory.hasCompatibleTrackedLayout(with: withInventory))
    }

    private static func weeklyResetTransitionModels() throws -> (
        frozen: UsageMenuCardView.Model,
        resolved: UsageMenuCardView.Model)
    {
        let now = Date(timeIntervalSince1970: 1_781_726_400)
        let later = now.addingTimeInterval(12 * 60 * 60)
        let credit = Self.credit(id: "finite", status: .available, now: now, expiresIn: 30 * 60 * 60)
        let frozen = try Self.model(
            snapshot: Self.snapshot(
                now: now,
                primary: RateWindow(
                    usedPercent: 45,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(24 * 60 * 60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 18,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                    resetDescription: nil),
                credits: [credit]),
            now: now)
        let resolved = try Self.model(
            snapshot: Self.snapshot(
                now: later,
                primary: RateWindow(
                    usedPercent: 45,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(24 * 60 * 60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(9 * 24 * 60 * 60),
                    resetDescription: nil),
                credits: [credit]),
            now: later)
        return (frozen, resolved)
    }

    private static func model(
        snapshot: UsageSnapshot,
        email: String? = nil,
        accountID: String? = nil,
        showOptionalUsage: Bool = true,
        resetStyle: ResetTimeDisplayStyle = .countdown,
        hidePersonalInfo: Bool = false,
        now: Date) throws -> UsageMenuCardView.Model
    {
        let snapshot = email.map {
            snapshot.withIdentity(ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: $0,
                accountOrganization: nil,
                loginMethod: nil,
                accountID: accountID))
        } ?? snapshot
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let codexProjection = CodexConsumerProjection.make(
            surface: .liveCard,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: now))
        return UsageMenuCardView.Model.make(UsageMenuCardView.Model.Input(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: codexProjection,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: email, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: resetStyle,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: showOptionalUsage,
            hidePersonalInfo: hidePersonalInfo,
            now: now))
    }

    private static func snapshot(
        now: Date,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        credits: [CodexRateLimitResetCredit],
        availableCount: Int? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
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
