import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

struct MenuCardCodexSessionQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [0.0, 37.0, 100.0], [false, true])
    func `weekly exhaustion preserves the session window and explains the block`(
        sessionUsed: Double,
        showUsed: Bool) throws
    {
        let (model, projection) = try self.model(sessionUsed: sessionUsed, showUsed: showUsed)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        let weekly = try #require(model.metrics.first { $0.id == "secondary" })

        #expect(session.percent == (showUsed ? sessionUsed : 100 - sessionUsed))
        #expect(session.resetText == "Resets in 1h")
        #expect(session.statusText == nil)
        #expect(session.warningText == L("Weekly limit reached"))
        #expect(session.helpText == L("Weekly limit reached"))
        #expect(session.pacePercent == nil)
        #expect(session.detailLeftText == nil)
        #expect(session.detailRightText == nil)
        #expect(weekly.percent == (showUsed ? 100 : 0))
        #expect(weekly.resetText == "Resets in 3d")

        // Keep the availability semantics introduced in #1930 for compact/status consumers.
        #expect(projection.hasBindingWeeklyCap)
        #expect(projection.rateWindow(for: .session)?.remainingPercent == 0)
        #expect(projection.rateWindow(for: .session)?.resetsAt == self.now.addingTimeInterval(3 * 86400))
    }

    @Test(arguments: [99.0, 100.0])
    func `a weekly window with room or a completed reset does not warn`(weeklyUsed: Double) throws {
        let (model, projection) = try self.model(
            sessionUsed: 37,
            weeklyUsed: weeklyUsed,
            weeklyResetOffset: weeklyUsed == 100 ? 0 : 3 * 86400)
        let session = try #require(model.metrics.first { $0.id == "primary" })

        #expect(session.percent == 63)
        #expect(session.resetText == "Resets in 1h")
        #expect(session.warningText == nil)
        #expect(session.helpText == nil)
        #expect(!projection.hasBindingWeeklyCap)
    }

    @Test
    func `an unknown weekly reset still explains the block without replacing the session reset`() throws {
        let (model, projection) = try self.model(weeklyResetOffset: nil)
        let session = try #require(model.metrics.first { $0.id == "primary" })

        #expect(session.percent == 100)
        #expect(session.resetText == "Resets in 1h")
        #expect(session.warningText == L("Weekly limit reached"))
        #expect(projection.hasBindingWeeklyCap)
        #expect(projection.rateWindow(for: .session)?.resetsAt == nil)
    }

    @Test(arguments: [CodexConsumerProjection.Surface.liveCard, .overrideCard])
    func `live and additional account cards preserve an unused session`(
        surface: CodexConsumerProjection.Surface) throws
    {
        let (model, _) = try self.model(surface: surface)
        let session = try #require(model.metrics.first { $0.id == "primary" })

        #expect(session.percentLabel == "100% left")
        #expect(session.resetText == "Resets in 1h")
        #expect(session.warningText == L("Weekly limit reached"))
    }

    @Test
    func `a weekly warning invalidates cached card height and tracked layout`() throws {
        let (model, _) = try self.model()
        let index = try #require(model.metrics.firstIndex { $0.id == "primary" })
        var withoutWarning = model
        withoutWarning.metrics[index].warningText = nil

        #expect(model.heightFingerprint(section: "card") != withoutWarning.heightFingerprint(section: "card"))
        #expect(!model.hasCompatibleTrackedLayout(with: withoutWarning))
        #expect(!withoutWarning.hasCompatibleTrackedLayout(with: model))
    }

    @Test
    @MainActor
    func `hiding weekly usage retains the blocking warning in provider settings`() throws {
        let (model, _) = try self.model()
        let visible = model.applyingUsageItemVisibility(hiddenItemIDs: [.metric("secondary")])
        let session = try #require(visible.metrics.first { $0.id == "primary" })

        #expect(visible.metrics.allSatisfy { $0.id != "secondary" })
        #expect(session.percentLabel == "100% left")
        #expect(session.resetText == "Resets in 1h")
        #expect(session.warningText == L("Weekly limit reached"))
        #expect(ProviderDetailView<EmptyView>.metricInlinePresentation(session) == .progress)
    }

    private func model(
        sessionUsed: Double = 0,
        weeklyUsed: Double = 100,
        weeklyResetOffset: TimeInterval? = 3 * 86400,
        showUsed: Bool = false,
        surface: CodexConsumerProjection.Surface = .liveCard) throws
        -> (UsageMenuCardView.Model, CodexConsumerProjection)
    {
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: sessionUsed,
                windowMinutes: 300,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: weeklyUsed,
                windowMinutes: 10080,
                resetsAt: weeklyResetOffset.map { self.now.addingTimeInterval($0) },
                resetDescription: nil),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)
        let projection = CodexConsumerProjection.make(
            surface: surface,
            context: .init(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: self.now))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            codexProjection: projection,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: showUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
        return (model, projection)
    }
}
