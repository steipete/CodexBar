import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardModelTests {
    @Test
    func `count labels avoid plural agreement and localize numbers`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardRefreshFailureText(1) == "Refresh failures: 1")
            #expect(spendDashboardRefreshFailureText(2) == "Refresh failures: 2")
            #expect(spendDashboardCoverageText(covered: 3, requested: 7) == "Coverage: 3 / 7")
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            #expect(spendDashboardRefreshFailureText(1234) == "Fehlgeschlagene Aktualisierungen: 1.234")
            #expect(spendDashboardCoverageText(covered: 3, requested: 30) == "Abdeckung: 3 / 30")
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("fa") {
            #expect(codexBarLocalizedInteger(12) == "۱۲")
            #expect(spendDashboardDayRangeText(7) == "۷ روز")
            #expect(spendDashboardDayRangeText(30) == "۳۰ روز")
            #expect(spendDashboardRankText(1234) == "#۱٬۲۳۴")
            #expect(spendDashboardRefreshFailureText(2) == "\(L("Refresh failures")): ۲")
            #expect(spendDashboardCoverageText(covered: 3, requested: 30) == "پوشش: ۳ / ۳۰")
        }
    }

    @Test
    func `Codex account indices use app locale numerals`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardModelTests-index-locale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = CodexVisibleAccount(
            id: "locale-account",
            email: "locale@example.com",
            authFingerprint: nil,
            storedAccountID: nil,
            selectionSource: .profileHome(path: home.path),
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)

        let persian = CodexBarLocalizationOverride.$appLanguage.withValue("fa") {
            SpendDashboardSource.codexRequest(
                account: account,
                homePath: home.path,
                providerName: "Codex",
                index: 1,
                count: 2)?.displayName
        }
        let arabic = CodexBarLocalizationOverride.$appLanguage.withValue("ar") {
            SpendDashboardSource.codexRequest(
                account: account,
                homePath: home.path,
                providerName: "Codex",
                index: 1,
                count: 2)?.displayName
        }

        #expect(persian == "Codex · #۲")
        #expect(arabic == "Codex · #٢")
    }

    @Test
    func `dashboard source contract includes only cost capable descriptors`() {
        let providers = Set(ProviderDescriptorRegistry.all
            .filter(\.tokenCost.supportsTokenCost)
            .map(\.id))
        #expect(providers == [.codex, .claude, .vertexai, .openai, .mistral, .bedrock, .cursor, .opencodego])
    }

    @Test
    func `native currencies stay separate and rank only within their currency`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "usd-low", provider: .claude, currency: "usd", cost: 2),
                Self.input(id: "eur", provider: .openai, currency: "EUR", cost: 100),
                Self.input(id: "usd-high", provider: .codex, currency: "USD", cost: 8),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.groups.map(\.currencyCode) == ["EUR", "USD"])
        let eur = try #require(model.groups.first)
        #expect(eur.providers.map(\.id) == ["eur"])
        #expect(eur.providers.map(\.rank) == [1])
        #expect(eur.totalCost == 100)
        #expect(eur.models.map(\.modelName) == ["test-model"])
        #expect(eur.models.map(\.totalCost) == [100])
        let usd = try #require(model.groups.last)
        #expect(usd.providers.map(\.id) == ["usd-high", "usd-low"])
        #expect(usd.providers.map(\.rank) == [1, 2])
        #expect(usd.totalCost == 10)
        #expect(usd.models.allSatisfy { $0.modelName == "test-model" })
        #expect(usd.models.compactMap(\.totalCost).reduce(0, +) == 10)
    }

    @Test
    func `windows anchor to injected now and report covered days honestly`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-16", cost: 1),
                Self.entry(day: "2026-07-09", cost: 2),
                Self.entry(day: "2026-07-08", cost: 4),
                Self.entry(day: "2026-08-01", cost: 100),
            ])
        let input = SpendDashboardModel.ProviderInput(provider: .claude, displayName: "Claude", snapshot: snapshot)

        let sevenDays = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(sevenDays.groups.first)
        #expect(group.totalCost == 1)
        #expect(group.coveredDayCount == 7)
        #expect(group.providers.first?.coveredDayCount == 7)

        let thirtyDays = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        #expect(thirtyDays.groups.first?.totalCost == 7)
        #expect(thirtyDays.groups.first?.coveredDayCount == 30)

        let futureSnapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "2026-07-16", cost: 1)],
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
        let futureModel = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: futureSnapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        #expect(futureModel.groups.first?.coveredDayCount == 0)

        let shortSnapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "2026-07-16", cost: 1)],
            historyDays: 7)
        let shortModel = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: shortSnapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        #expect(shortModel.groups.first?.coveredDayCount == 7)
    }

    @Test
    func `chart domain uses the exact requested window despite sparse points`() throws {
        let input = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 1)]))
        let sevenDays = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let thirtyDays = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let anchor = Self.calendar.startOfDay(for: Self.now)
        let sevenDayStart = try #require(Self.calendar.date(byAdding: .day, value: -6, to: anchor))
        let thirtyDayStart = try #require(Self.calendar.date(byAdding: .day, value: -29, to: anchor))
        let end = try #require(Self.calendar.date(byAdding: .day, value: 1, to: anchor))

        #expect(sevenDays.dailyPoints.map(\.day) == [anchor])
        #expect(thirtyDays.dailyPoints.map(\.day) == [anchor])
        #expect(sevenDays.chartDomain == sevenDayStart...end)
        #expect(thirtyDays.chartDomain == thirtyDayStart...end)
    }

    @Test
    func `currency coverage intersects disjoint provider windows`() throws {
        let earlier = try SpendDashboardModel.ProviderInput(
            id: "earlier",
            provider: .claude,
            displayName: "Earlier",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-09", cost: 2)],
                historyDays: 7,
                updatedAt: #require(Self.calendar.date(byAdding: .day, value: -7, to: Self.now))))
        let later = SpendDashboardModel.ProviderInput(
            id: "later",
            provider: .codex,
            displayName: "Later",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 3)],
                historyDays: 7))
        let group = try #require(SpendDashboardModel.build(
            inputs: [earlier, later],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 0)
        #expect(group.providers.allSatisfy { $0.coveredDayCount == 7 })
        #expect(group.totalCost == 5)
        #expect(group.providers.map(\.id) == ["later", "earlier"])
        #expect(group.dailyPoints.map(\.sourceID) == ["earlier", "later"])
    }

    @Test
    func `currency coverage counts only overlapping provider days`() throws {
        let earlier = try SpendDashboardModel.ProviderInput(
            id: "earlier",
            provider: .claude,
            displayName: "Earlier",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-12", cost: 2)],
                historyDays: 7,
                updatedAt: #require(Self.calendar.date(byAdding: .day, value: -4, to: Self.now))))
        let later = SpendDashboardModel.ProviderInput(
            id: "later",
            provider: .codex,
            displayName: "Later",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 3)],
                historyDays: 7))
        let group = try #require(SpendDashboardModel.build(
            inputs: [earlier, later],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 3)
        #expect(group.providers.allSatisfy { $0.coveredDayCount == 7 })
        #expect(group.totalCost == 5)
    }

    @Test
    func `uncovered same currency source keeps complete model rows without ranking them as complete`() throws {
        let covered = Self.input(id: "covered", provider: .claude, currency: "USD", cost: 4)
        let uncovered = SpendDashboardModel.ProviderInput(
            id: "uncovered",
            provider: .codex,
            displayName: "Uncovered",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-08-01", cost: 10)],
                historyDays: 1,
                updatedAt: Date(timeIntervalSince1970: 1_785_542_400))) // 2026-08-01 00:00:00 UTC
        let group = try #require(SpendDashboardModel.build(
            inputs: [covered, uncovered],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.provider) == [.claude])
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [4])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
    }

    @Test
    func `only uncovered source reports model breakdown unavailable`() throws {
        let uncovered = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-08-01", cost: 10)],
                historyDays: 1,
                updatedAt: Date(timeIntervalSince1970: 1_785_542_400))) // 2026-08-01 00:00:00 UTC
        let group = try #require(SpendDashboardModel.build(
            inputs: [uncovered],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 0)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(group) == .unavailable)
    }

    @Test
    func `uncovered source affects only its own currency model history`() throws {
        let covered = Self.input(id: "covered", provider: .claude, currency: "USD", cost: 4)
        let uncovered = SpendDashboardModel.ProviderInput(
            id: "uncovered",
            provider: .codex,
            displayName: "Uncovered",
            snapshot: Self.snapshot(
                currency: "EUR",
                entries: [Self.entry(day: "2026-08-01", cost: 10)],
                historyDays: 1,
                updatedAt: Date(timeIntervalSince1970: 1_785_542_400))) // 2026-08-01 00:00:00 UTC
        let groups = SpendDashboardModel.build(
            inputs: [covered, uncovered],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups
        let eur = try #require(groups.first(where: { $0.currencyCode == "EUR" }))
        let usd = try #require(groups.first(where: { $0.currencyCode == "USD" }))

        #expect(eur.modelHistoryCompleteness == .incomplete)
        #expect(eur.models.isEmpty)
        #expect(usd.modelHistoryCompleteness == .complete)
        #expect(usd.models.map(\.totalCost) == [4])
    }

    @Test
    func `ISO history stays Gregorian while preserving the injected timezone`() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 7 * 60 * 60))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let now = try #require(gregorian.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 16,
            hour: 12)))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = timeZone
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "2026-07-16", cost: 4)],
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: now,
            calendar: buddhist).groups.first)

        #expect(group.totalCost == 4)
        #expect(group.coveredDayCount == 7)
        #expect(group.dailyPoints.map(\.day) == [gregorian.startOfDay(for: now)])
    }

    @Test
    func `daily values aggregate once and produce deterministic nonoverlapping stacks`() throws {
        let first = SpendDashboardModel.ProviderInput(
            id: "a",
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 2),
                Self.entry(day: "2026-07-16", cost: 3),
            ]))
        let second = SpendDashboardModel.ProviderInput(
            id: "b",
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(currency: "USD", entries: [Self.entry(day: "2026-07-16", cost: 4)]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [second, first],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailyPoints.map(\.sourceID) == ["a", "b"])
        #expect(group.dailyPoints.map(\.cost) == [5, 4])
        #expect(group.dailyPoints.map(\.stackStart) == [0, 5])
        #expect(group.dailyPoints.map(\.stackEnd) == [5, 9])
    }

    @Test
    func `invalid costs and arithmetic overflow never become spend`() throws {
        let invalid = SpendDashboardModel.ProviderInput(
            id: "invalid",
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: -.infinity, tokens: .max),
                Self.entry(day: "2026-07-15", cost: -.nan, tokens: .max),
                Self.entry(day: "2026-07-14", cost: -1),
                Self.entry(day: "2026-06-31", cost: 99),
            ]))
        let hugeA = Self.input(id: "huge-a", provider: .codex, currency: "USD", cost: .greatestFiniteMagnitude)
        let hugeB = Self.input(id: "huge-b", provider: .openai, currency: "USD", cost: .greatestFiniteMagnitude)
        let group = try #require(SpendDashboardModel.build(
            inputs: [invalid, hugeA, hugeB],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first(where: { $0.id == "invalid" })?.totalCost == nil)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `malformed date mixed with valid usage fails the source closed`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16", cost: 4, tokens: 40),
            Self.entry(day: "not-a-day", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == nil)
        #expect(group.providers.first?.totalTokens == nil)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `malformed date only with unknown usage is unavailable not zero`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-02-30", cost: nil, tokens: nil, model: nil),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == nil)
        #expect(group.providers.first?.totalTokens == nil)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `explicit zero malformed date is ignored without affecting valid window rows`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "malformed", cost: 0, tokens: 0, model: nil),
            Self.entryWithBreakdowns(
                day: "also-malformed",
                totalCost: 0,
                totalTokens: 0,
                breakdowns: [.init(modelName: "zero", costUSD: 0, totalTokens: 0, requestCount: 0)]),
            Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            Self.entry(day: "2026-07-01", cost: 99, tokens: 990),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == 3)
        #expect(group.providers.first?.totalTokens == 30)
        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [3])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `mixed invalid entry metrics make source and group totals unavailable`() throws {
        let inputs = [
            SpendDashboardModel.ProviderInput(
                id: "missing",
                provider: .claude,
                displayName: "Missing",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: 1, tokens: 1),
                    Self.entry(day: "2026-07-15", cost: nil, tokens: nil),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "negative",
                provider: .codex,
                displayName: "Negative",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: 1, tokens: 1),
                    Self.entry(day: "2026-07-15", cost: -1, tokens: -1),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "nonfinite",
                provider: .openai,
                displayName: "Nonfinite",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: 1, tokens: 1),
                    Self.entry(day: "2026-07-15", cost: .infinity, tokens: 1),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "overflow",
                provider: .mistral,
                displayName: "Overflow",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: .greatestFiniteMagnitude, tokens: .max),
                    Self.entry(day: "2026-07-15", cost: .greatestFiniteMagnitude, tokens: .max),
                ])),
        ]
        let group = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.allSatisfy { $0.totalCost == nil })
        #expect(group.providers.first(where: { $0.id == "nonfinite" })?.totalTokens == 2)
        #expect(group.providers.filter { $0.id != "nonfinite" }.allSatisfy { $0.totalTokens == nil })
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
    }

    @Test
    func `invalid model breakdowns make model history unavailable`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entryWithBreakdowns(
                day: "2026-07-16",
                breakdowns: [
                    .init(modelName: "complete", costUSD: 2, totalTokens: 2),
                    .init(modelName: "missing", costUSD: 4, totalTokens: 4),
                    .init(modelName: "negative", costUSD: 4, totalTokens: 4),
                    .init(modelName: "overflow", costUSD: .greatestFiniteMagnitude, totalTokens: .max),
                ]),
            Self.entryWithBreakdowns(
                day: "2026-07-15",
                breakdowns: [
                    .init(modelName: "complete", costUSD: 1, totalTokens: 1),
                    .init(modelName: "missing", costUSD: nil, totalTokens: nil),
                    .init(modelName: "negative", costUSD: -1, totalTokens: -1),
                    .init(modelName: "overflow", costUSD: .greatestFiniteMagnitude, totalTokens: .max),
                ]),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `partial contributing model history is unavailable instead of a lower bound`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16", cost: 4, tokens: 40, model: nil),
            Self.entry(day: "2026-07-15", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(group.totalCost == 6)
    }

    @Test
    func `zero usage without a breakdown keeps model history complete`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entryWithBreakdowns(day: "2026-07-16", breakdowns: []),
            Self.entry(day: "2026-07-15", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [2])
    }

    @Test
    func `unknown usage without a breakdown makes model history unavailable`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16", cost: nil, tokens: nil, model: nil),
            Self.entry(day: "2026-07-15", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `blank model names fail closed unless their usage is explicitly zero`() throws {
        let incomplete = Self.snapshot(currency: "USD", entries: [Self.entryWithBreakdowns(
            day: "2026-07-16",
            totalCost: 3,
            totalTokens: 30,
            breakdowns: [
                .init(modelName: " \n ", costUSD: 2, totalTokens: 20),
                .init(modelName: "named", costUSD: 1, totalTokens: 10),
            ])])
        let complete = Self.snapshot(currency: "USD", entries: [Self.entryWithBreakdowns(
            day: "2026-07-16",
            totalCost: 1,
            totalTokens: 10,
            breakdowns: [
                .init(modelName: " \n ", costUSD: 0, totalTokens: 0),
                .init(modelName: "named", costUSD: 1, totalTokens: 10),
            ])])
        let incompleteGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: incomplete)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let completeGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: complete)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(incompleteGroup.modelHistoryCompleteness == .incomplete)
        #expect(incompleteGroup.models.isEmpty)
        #expect(completeGroup.modelHistoryCompleteness == .complete)
        #expect(completeGroup.models.map(\.modelName) == ["named"])
    }

    @Test
    func `partial named breakdown totals make model history unavailable`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [Self.entryWithBreakdowns(
            day: "2026-07-16",
            totalCost: 10,
            totalTokens: 100,
            breakdowns: [.init(modelName: "partial", costUSD: 4, totalTokens: 40)])])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `incomplete duplicate day sources do not render partial chart stacks`() throws {
        let missing = SpendDashboardModel.ProviderInput(
            id: "missing",
            provider: .claude,
            displayName: "Missing",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 2),
                Self.entry(day: "2026-07-16", cost: nil),
            ]))
        let overflow = SpendDashboardModel.ProviderInput(
            id: "overflow",
            provider: .codex,
            displayName: "Overflow",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: .greatestFiniteMagnitude),
                Self.entry(day: "2026-07-16", cost: .greatestFiniteMagnitude),
            ]))
        let complete = Self.input(id: "complete", provider: .openai, currency: "USD", cost: 3)
        let group = try #require(SpendDashboardModel.build(
            inputs: [missing, overflow, complete],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailyPoints.map(\.sourceID) == ["complete"])
        #expect(group.dailyPoints.map(\.cost) == [3])
        #expect(group.dailyPoints.map(\.stackStart) == [0])
        #expect(group.dailyPoints.map(\.stackEnd) == [3])
    }

    @Test
    func `covered inactive sources contribute zero without hiding active totals`() throws {
        let inactive = SpendDashboardModel.ProviderInput(
            id: "inactive",
            provider: .claude,
            displayName: "Inactive",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 0, tokens: 0, model: nil),
            ]))
        let active = Self.input(id: "active", provider: .codex, currency: "USD", cost: 10)
        let group = try #require(SpendDashboardModel.build(
            inputs: [inactive, active],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        let inactiveRow = try #require(group.providers.first(where: { $0.id == "inactive" }))
        #expect(inactiveRow.totalCost == 0)
        #expect(inactiveRow.totalTokens == 0)
        #expect(inactiveRow.coveredDayCount == 7)
        #expect(group.totalCost == 10)
        #expect(group.totalTokens == 10)
        #expect(group.providers.map(\.id) == ["active", "inactive"])
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [10])
    }

    @Test
    func `unpriced history stays unavailable instead of becoming zero`() throws {
        let snapshot = Self.snapshot(
            currency: "CAD",
            entries: [Self.entry(day: "2026-07-16", cost: nil, tokens: 12)])
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(model.groups.first)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 12)
        #expect(group.providers.first?.totalCost == nil)
    }

    @Test
    func `Codex requests freeze source home auth and cache identity`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = CodexVisibleAccount(
            id: "account",
            email: "test@example.com",
            authFingerprint: "ABC123",
            storedAccountID: id,
            selectionSource: .managedAccount(id: id),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let request = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: home.path,
            providerName: "Codex",
            index: 1,
            count: 2))

        #expect(request.source == .managedAccount(id: id))
        #expect(request.homePath == home.path)
        #expect(request.authFingerprint == "abc123")
        #expect(!request.authFileWasReadable)
        #expect(request.displayName == "Codex · #2")
        #expect(request.cacheIdentity.count == 64)
        #expect(SpendDashboardSource.scanDays == 30)
        #expect(SpendDashboardSource.codexRequest(
            account: account,
            homePath: "relative/path",
            providerName: "Codex",
            index: 0,
            count: 1) == nil)
        #expect(SpendDashboardSource.codexRequest(
            account: account,
            homePath: home.appendingPathComponent("missing", isDirectory: true).path,
            providerName: "Codex",
            index: 0,
            count: 1) == nil)

        let changed = CodexVisibleAccount(
            id: account.id,
            email: account.email,
            authFingerprint: "different",
            storedAccountID: id,
            selectionSource: account.selectionSource,
            isActive: account.isActive,
            isLive: account.isLive,
            canReauthenticate: account.canReauthenticate,
            canRemove: account.canRemove)
        let changedRequest = try #require(SpendDashboardSource.codexRequest(
            account: changed,
            homePath: request.homePath,
            providerName: "Codex",
            index: 1,
            count: 2))
        #expect(changedRequest.cacheIdentity != request.cacheIdentity)

        let authData = Data("{\"tokens\":\"synthetic\"}".utf8)
        try authData.write(to: CodexAuthFingerprint.authFileURL(homePath: home.path))
        let exact = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: home.path,
            providerName: "Codex",
            index: 0,
            count: 1))
        #expect(exact.authFingerprint == CodexAuthFingerprint.fingerprint(data: authData))
        #expect(exact.authFileWasReadable)
        #expect(exact.cacheIdentity != request.cacheIdentity)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        currency: String,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            snapshot: self.snapshot(currency: currency, entries: [self.entry(day: "2026-07-16", cost: cost)]))
    }

    private static func snapshot(
        currency: String,
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int = 30,
        updatedAt: Date = now) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: currency,
            historyDays: historyDays,
            daily: entries,
            updatedAt: updatedAt)
    }

    private static func entry(
        day: String,
        cost: Double?,
        tokens: Int? = 10,
        model: String? = "test-model") -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: model.map {
                [.init(modelName: $0, costUSD: cost, totalTokens: tokens)]
            })
    }

    private static func entryWithBreakdowns(
        day: String,
        totalCost: Double = 0,
        totalTokens: Int = 0,
        breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: totalTokens,
            costUSD: totalCost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
