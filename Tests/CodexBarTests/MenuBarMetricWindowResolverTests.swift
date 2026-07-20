import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct MenuBarMetricWindowResolverTests {
    @Test
    func `gemini metrics fall back to Flash when Pro is unavailable`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(usedPercent: 95, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 40, windowMinutes: 1440, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        for preference in [MenuBarMetricPreference.automatic, .primary, .average] {
            let window = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .gemini,
                snapshot: snapshot,
                supportsAverage: true)

            #expect(window?.usedPercent == 95, "Failed preference: \(preference)")
        }
    }

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
    func `automatic metric prioritizes exhausted litellm personal budget over active team budget`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "Personal"),
            secondary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "Team"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .litellm,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "Personal")
        #expect(window?.usedPercent == 100)
    }

    @Test
    func `automatic metric prioritizes exhausted litellm team budget over active personal budget`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: "Personal"),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "Team"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .litellm,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "Team")
        #expect(window?.usedPercent == 100)
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
    func `automatic metric prefers antigravity session window over weekly when none are exhausted`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: "5h"),
            secondary: RateWindow(
                usedPercent: 15,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "weekly"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        // Session (5-hour) windows should be preferred even though weekly windows
        // have higher usedPercent, because the session limit is the immediate constraint.
        #expect(window?.windowMinutes == 300)
        #expect(window?.resetDescription == "5h")
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
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: true)
        let secondary = MenuBarMetricWindowResolver.rateWindow(
            preference: .secondary,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: true)
        let tertiary = MenuBarMetricWindowResolver.rateWindow(
            preference: .tertiary,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: true)

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

    @Test
    func `automatic metric prioritizes exhausted kimi weekly quota over active rate limit`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: "Weekly"),
            secondary: RateWindow(usedPercent: 4, windowMinutes: 300, resetsAt: nil, resetDescription: "5-hour"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .kimi,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "Weekly")
        #expect(window?.usedPercent == 100)
    }

    @Test
    func `automatic metric prioritizes exhausted kimi rate limit over active weekly quota`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "Weekly"),
            secondary: RateWindow(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: "5-hour"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .kimi,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "5-hour")
        #expect(window?.usedPercent == 100)
    }

    @Test
    func `automatic metric defaults to rate limit for kimi when neither is exhausted`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: "Weekly"),
            secondary: RateWindow(usedPercent: 4, windowMinutes: 300, resetsAt: nil, resetDescription: "5-hour"),
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .kimi,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.resetDescription == "5-hour")
        #expect(window?.usedPercent == 4)
    }
}
