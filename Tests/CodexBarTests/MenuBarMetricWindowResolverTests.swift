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
    func `automatic metric preserves usable first by default and prioritizes exhausted lane when enabled`() {
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

        let defaultWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)
        let optInWindow = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false,
            antigravityPrioritizeExhaustedQuotas: true)

        #expect(defaultWindow?.remainingPercent == 29)
        #expect(defaultWindow?.windowMinutes == 300)
        #expect(optInWindow?.remainingPercent == 0)
        #expect(optInWindow?.windowMinutes == 300)
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
    func `automatic metric keeps legacy antigravity compact fallback usable first semantics`() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-compact-fallback-exhausted",
                    title: "Exhausted",
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-compact-fallback-usable",
                    title: "Usable",
                    window: RateWindow(
                        usedPercent: 64,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date())

        let window = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .antigravity,
            snapshot: snapshot,
            supportsAverage: false)

        #expect(window?.usedPercent == 64)
    }

    @Test
    func `antigravity quota ranking filters unknown and unsupported lanes`() {
        let now = Date(timeIntervalSince1970: 100_000)
        let expectedReset = now.addingTimeInterval(120)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-session",
                    title: "Gemini Session",
                    window: RateWindow(
                        usedPercent: 85,
                        windowMinutes: 300,
                        resetsAt: expectedReset,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-daily",
                    title: "Gemini Daily",
                    window: RateWindow(
                        usedPercent: 100,
                        windowMinutes: 1440,
                        resetsAt: now.addingTimeInterval(60),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(
                        usedPercent: 99,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(30),
                        resetDescription: nil),
                    usageKnown: false),
                NamedRateWindow(
                    id: "antigravity-quota-summary-invalid-session",
                    title: "Invalid Session",
                    window: RateWindow(
                        usedPercent: .nan,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(10),
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let window = MenuBarMetricWindowResolver.antigravityQuotaSummaryRankingWindow(
            snapshot: snapshot,
            now: now)

        #expect(window?.usedPercent == 85)
        #expect(window?.resetsAt == expectedReset)
    }

    @Test
    func `antigravity quota ranking breaks usage ties by valid nearest reset`() {
        let now = Date(timeIntervalSince1970: 100_000)
        let nearestFutureReset = now.addingTimeInterval(60)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-session",
                    title: "Gemini Session",
                    window: RateWindow(
                        usedPercent: 90,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-claude-session",
                    title: "Claude Session",
                    window: RateWindow(
                        usedPercent: 90,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(-60),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gpt-session",
                    title: "GPT Session",
                    window: RateWindow(
                        usedPercent: 90,
                        windowMinutes: 300,
                        resetsAt: now.addingTimeInterval(120),
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-other-session",
                    title: "Other Session",
                    window: RateWindow(
                        usedPercent: 90,
                        windowMinutes: 300,
                        resetsAt: nearestFutureReset,
                        resetDescription: nil)),
            ],
            updatedAt: now)

        let window = MenuBarMetricWindowResolver.antigravityQuotaSummaryRankingWindow(
            snapshot: snapshot,
            now: now)

        #expect(window?.resetsAt == nearestFutureReset)
    }

    @Test
    func `antigravity quota ranking breaks complete ties by stable row ID`() {
        let now = Date(timeIntervalSince1970: 100_000)
        let rows = [
            NamedRateWindow(
                id: "antigravity-quota-summary-a-weekly",
                title: "A Weekly",
                window: RateWindow(
                    usedPercent: 90,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: "a")),
            NamedRateWindow(
                id: "antigravity-quota-summary-z-session",
                title: "Z Session",
                window: RateWindow(
                    usedPercent: 90,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: "z")),
        ]

        for orderedRows in [rows, Array(rows.reversed())] {
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                extraRateWindows: orderedRows,
                updatedAt: now)
            let window = MenuBarMetricWindowResolver.antigravityQuotaSummaryRankingWindow(
                snapshot: snapshot,
                now: now)

            #expect(window?.resetDescription == "z")
        }
    }

    @Test
    func `antigravity families are blocked only when every understood family has an exhausted lane`() {
        let snapshot = Self.antigravitySummarySnapshot(rows: [
            ("gemini-session", 300, 100, true),
            ("gemini-weekly", 10080, 20, true),
            ("3p-5-hour", 300, 10, true),
            ("3p-weekly", 10080, 100, true),
        ])

        #expect(MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot))

        let availableFamily = Self.antigravitySummarySnapshot(rows: [
            ("gemini-session", 300, 100, true),
            ("3p-session", 300, 99, true),
        ])
        #expect(!MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: availableFamily))
    }

    @Test
    func `antigravity family blocking accepts underscore cadence delimiters`() {
        let snapshot = Self.antigravitySummarySnapshot(rows: [
            ("gemini_session", 300, 100, true),
            ("gemini_weekly", 10080, 20, true),
            ("third_party_five_hour", 300, 100, true),
        ])

        #expect(MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot))
    }

    @Test
    func `antigravity family blocking accepts limit suffixed cadence`() {
        let snapshot = Self.antigravitySummarySnapshot(rows: [
            ("gemini-5h limit", 300, 100, true),
            ("gemini-weekly limit", 10080, 20, true),
            ("third-party-session limit", 300, 100, true),
        ])

        #expect(MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot))
    }

    @Test(arguments: [
        ("gemini-session", 300, 100.0, false),
        ("gemini-daily", 1440, 100.0, true),
        ("-session", 300, 100.0, true),
        ("gemini-daily", 300, 100.0, true),
        ("gem ini-session", 300, 100.0, true),
        ("invalid-session", 300, Double.nan, true),
    ])
    func `antigravity family blocking fails open for incomplete summary rows`(
        idSuffix: String,
        windowMinutes: Int,
        usedPercent: Double,
        usageKnown: Bool)
    {
        let snapshot = Self.antigravitySummarySnapshot(rows: [
            ("safe-session", 300, 100, true),
            (idSuffix, windowMinutes, usedPercent, usageKnown),
        ])

        #expect(!MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot))
    }

    @Test
    func `antigravity family blocking fails open without quota summary rows`() {
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())

        #expect(!MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot))
    }

    private static func antigravitySummarySnapshot(
        rows: [(idSuffix: String, windowMinutes: Int, usedPercent: Double, usageKnown: Bool)])
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: rows.map { row in
                NamedRateWindow(
                    id: "antigravity-quota-summary-\(row.idSuffix)",
                    title: row.idSuffix,
                    window: RateWindow(
                        usedPercent: row.usedPercent,
                        windowMinutes: row.windowMinutes,
                        resetsAt: nil,
                        resetDescription: nil),
                    usageKnown: row.usageKnown)
            },
            updatedAt: Date())
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
}
