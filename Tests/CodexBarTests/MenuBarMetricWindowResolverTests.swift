import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarMetricWindowResolverTests {
    @Test
    func `automatic metric uses zai 5-hour token lane when it is most constrained`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 92, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .zai,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 92)
    }

    @Test
    func `automatic metric uses minimax weekly token lane when it is most constrained`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 97, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .minimax,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 97)
        #expect(window?.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `combined primary and secondary metric uses the most constrained lane`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 91, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .primaryAndSecondary,
            provider: .codex,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 91)
        #expect(window?.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `automatic metric skips exhausted cursor subquota when total remains usable`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 67, windowMinutes: 30 * 24 * 60, resetsAt: nil, resetDescription: "Total"),
            secondary: RateWindow(
                usedPercent: 34,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Auto"),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: 30 * 24 * 60, resetsAt: nil, resetDescription: "API"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.remainingPercent == 33)
        #expect(window?.resetDescription == "Total")
    }

    @Test
    func `automatic metric still reports cursor exhausted when every subquota is exhausted`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Total"),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Auto"),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: 30 * 24 * 60, resetsAt: nil, resetDescription: "API"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.remainingPercent == 0)
    }

    @Test
    func `automatic metric keeps exhausted cursor total when a subquota remains usable`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Total"),
            secondary: RateWindow(
                usedPercent: 60,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Auto"),
            tertiary: nil,
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.remainingPercent == 0)
        #expect(window?.resetDescription == "Total")
    }

    @Test
    func `automatic metric reports cursor exhausted when all present subquotas are exhausted`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 67, windowMinutes: 30 * 24 * 60, resetsAt: nil, resetDescription: "Total"),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 30 * 24 * 60,
                resetsAt: nil,
                resetDescription: "Auto"),
            tertiary: RateWindow(usedPercent: 100, windowMinutes: 30 * 24 * 60, resetsAt: nil, resetDescription: "API"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.remainingPercent == 0)
    }

    @Test
    func `automatic metric preserves exhausted minimax session lane`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 97, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .minimax,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 100)
        #expect(window?.windowMinutes == 300)
    }

    @Test
    func `automatic metric uses team budget for team-bound LiteLLM keys`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Personal"),
            secondary: RateWindow(
                usedPercent: 80,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "Team"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .litellm,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 80)
        #expect(window?.resetDescription == "Team")
    }

    @Test
    func `automatic metric uses constrained antigravity family lane`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "Claude"),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "Gemini Pro"),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "Gemini Flash"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 100)
        #expect(window?.resetDescription == "Gemini Pro")
    }

    @Test
    func `automatic metric skips exhausted antigravity five hour bucket when another remains usable`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 67, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models Five Hour Limit",
                    window: RateWindow(usedPercent: 71, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    window: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude and GPT models Five Hour Limit",
                    window: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT models Weekly Limit",
                    window: RateWindow(usedPercent: 67, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.remainingPercent == 29)
        #expect(window?.windowMinutes == 300)
    }

    @Test
    func `automatic metric uses recognized antigravity gemini pool when claude gpt is reset only`() throws {
        let resetOnlyReset = Date(timeIntervalSince1970: 1000)
        let exhaustedReset = Date(timeIntervalSince1970: 2000)
        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6",
                    modelId: "claude-sonnet-4-6",
                    remainingFraction: nil,
                    resetTime: resetOnlyReset,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro",
                    modelId: "gemini-3-1-pro",
                    remainingFraction: 0,
                    resetTime: exhaustedReset,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)
        let snapshot = try antigravitySnapshot.toUsageSnapshot()
        #expect(snapshot.primary?.usedPercent == 100)
        #expect(snapshot.primary?.resetsAt == exhaustedReset)
        #expect(snapshot.secondary == nil)

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 100)
        #expect(window?.resetsAt == exhaustedReset)
    }

    @Test
    func `automatic metric uses unclassified antigravity compact fallback`() throws {
        let antigravitySnapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Model",
                    modelId: "MODEL_PLACEHOLDER_NEW",
                    remainingFraction: 0.36,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)
        let snapshot = try antigravitySnapshot.toUsageSnapshot()

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 64)
    }

    @Test
    func `explicit antigravity metric keeps requested family lane`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: "Claude"),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "Gemini Pro"),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "Gemini Flash"),
            updatedAt: Date())

        let primary = MenuBarMetricWindowResolver.rateWindow(
            preference: .primary,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)
        let secondary = MenuBarMetricWindowResolver.rateWindow(
            preference: .secondary,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)
        let tertiary = MenuBarMetricWindowResolver.rateWindow(
            preference: .tertiary,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(primary?.resetDescription == "Claude")
        #expect(secondary?.resetDescription == "Gemini Pro")
        #expect(tertiary?.resetDescription == "Gemini Flash")
    }

    @Test
    func `monthly plan metric selects Mistral subscription window`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "mistral-monthly-plan",
                    title: "Monthly Plan",
                    window: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .monthlyPlan,
            provider: .mistral,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 42)
    }

    @Test
    func `extra usage metric maps provider cost into a menu bar window`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 37.5,
                limit: 150,
                currencyCode: "USD",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .extraUsage,
            provider: .cursor,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 25)
    }

    @Test
    func `automatic metric uses claude enterprise spend limit`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Spend limit",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(abs((window?.usedPercent ?? 0) - 6.703) < 0.0001)
    }

    @Test
    func `automatic metric uses marked claude web spend limit placeholder`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(abs((window?.usedPercent ?? 0) - 6.703) < 0.0001)
    }

    @Test
    func `combined metric keeps real zero claude session when spend limit exists`() {
        let primary = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .primaryAndSecondary,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window == primary)
    }

    @Test
    func `automatic metric keeps real zero claude session when spend limit exists`() {
        let primary = RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window == primary)
    }

    @Test
    func `automatic metric keeps claude quota window when extra usage is optional`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 42)
    }

    @Test
    func `automatic metric keeps claude zero quota window when reset exists`() {
        let reset = Date(timeIntervalSince1970: 1000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: reset, resetDescription: "later"),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 67.03,
                limit: 1000,
                currencyCode: "USD",
                period: "Monthly",
                updatedAt: Date()),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .claude,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetsAt == reset)
    }
}
