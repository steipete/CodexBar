import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuCardBindingQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func model(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        usageBarsShowUsed: Bool = false) throws -> UsageMenuCardView.Model
    {
        let metadata = try #require(ProviderDefaults.metadata[provider])
        return UsageMenuCardView.Model.make(.init(
            provider: provider,
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
            usageBarsShowUsed: usageBarsShowUsed,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: self.now))
    }

    private func primary(
        usedPercent: Double = 40,
        minutes: Int = 5 * 60,
        resetsAt: Date? = nil,
        resetDescription: String? = nil) -> RateWindow
    {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: minutes,
            resetsAt: resetsAt,
            resetDescription: resetDescription)
    }

    @Test
    func `weekly exhaustion caps the session row with the weekly reset`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600 + 5 * 3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 3d 5h")
        let weekly = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(weekly.percentLabel == "0% left")
    }

    @Test
    func `session row keeps its own percent when the weekly lane has room`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 30,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(4 * 24 * 3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
        #expect(session.resetText == "Resets in 2h")
    }

    @Test
    func `expired weekly reset stops capping a stale snapshot`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(-3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
    }

    @Test
    func `reset exactly at evaluation time stops capping`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 120,
                minutes: 7 * 24 * 60,
                resetsAt: self.now),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
    }

    @Test
    func `model-scoped tertiary does not cap the session row`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 30,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(4 * 24 * 3600)),
            tertiary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(2 * 24 * 3600)),
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
    }

    @Test
    func `monthly exhaustion caps the session row when monthly is binding`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 30,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(4 * 24 * 3600)),
            tertiary: self.primary(
                usedPercent: 100,
                minutes: 30 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(10 * 24 * 3600)),
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .doubao, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 10d")
    }

    @Test
    func `weekly exhaustion caps the session row even when monthly has room`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600)),
            tertiary: self.primary(
                usedPercent: 30,
                minutes: 30 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(10 * 24 * 3600)),
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .doubao, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 3d")
    }

    @Test
    func `multiple exhausted lanes use the final unblock reset`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(5 * 24 * 3600)),
            tertiary: self.primary(
                usedPercent: 100,
                minutes: 30 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(2 * 24 * 3600)),
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .doubao, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 5d")
    }

    @Test
    func `unknown exhausted reset suppresses an earlier known promise`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(5 * 24 * 3600)),
            tertiary: self.primary(
                usedPercent: 100,
                minutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "monthly reset pending"),
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .doubao, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == nil)
    }

    @Test
    func `binding projection preserves primary provider detail`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(
                resetsAt: self.now.addingTimeInterval(2 * 3600),
                resetDescription: "40 / 100 flows"),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600),
                resetDescription: "1000 / 1000 used"),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .zenmux, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 3d")
        #expect(session.detailLeftText == "40 / 100 flows")
    }

    @Test
    func `command code purchased credits keep the monthly grant nonbinding`() throws {
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let snapshot = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 0,
            purchasedCredits: 5,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            fiveHourWindow: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            weeklyWindow: self.primary(
                usedPercent: 30,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(4 * 24 * 3600)),
            plan: plan,
            billingPeriodEnd: self.now.addingTimeInterval(10 * 24 * 3600),
            subscriptionStatus: "active",
            updatedAt: self.now)
            .toUsageSnapshot()

        let model = try self.model(provider: .commandcode, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
        #expect(session.resetText == "Resets in 2h")
    }

    @Test
    func `used direction renders the capped row as fully used`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot, usageBarsShowUsed: true)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "100% used")
        #expect(session.resetText == "Resets in 3d")
    }

    @Test
    func `textual binding reset shows instead of a dead percent`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: "resets in 6 hours"),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 6 hours")
    }

    @Test
    func `both lanes exhausted shows the later session reset`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(
                usedPercent: 100,
                resetsAt: self.now.addingTimeInterval(5 * 24 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "0% left")
        #expect(session.resetText == "Resets in 5d")
    }

    @Test
    func `providers without the policy never cap the session row`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(resetsAt: self.now.addingTimeInterval(2 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .copilot, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
    }

    @Test
    func `shorter secondary never caps a longer primary`() throws {
        let snapshot = UsageSnapshot(
            primary: self.primary(
                usedPercent: 40,
                minutes: 7 * 24 * 60,
                resetsAt: self.now.addingTimeInterval(3 * 24 * 3600)),
            secondary: self.primary(
                usedPercent: 100,
                resetsAt: self.now.addingTimeInterval(2 * 3600)),
            tertiary: nil,
            updatedAt: self.now,
            identity: nil)

        let model = try self.model(provider: .claude, snapshot: snapshot)
        let session = try #require(model.metrics.first { $0.id == "primary" })
        #expect(session.percentLabel == "60% left")
    }
}
