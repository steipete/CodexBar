import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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
            #expect(spendDashboardDayRangeText(SpendDashboardSource.scanDays) == "همه")
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
        #expect(providers == [
            .codex, .claude, .vertexai, .openai, .mistral, .bedrock, .cursor, .grok, .opencodego, .openrouter, .xai,
            .antigravity, .openclaw,
        ])
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

        let cumulativeSnapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-16", cost: 1),
                Self.entry(day: "2026-07-09", cost: 2),
                Self.entry(day: "2026-07-08", cost: 4),
                Self.entry(day: "2026-06-06", cost: 8),
                Self.entry(day: "2026-08-01", cost: 100),
            ],
            historyDays: SpendDashboardSource.scanDays)
        let cumulativeInput = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: cumulativeSnapshot)
        #expect(SpendDashboardModel.build(
            inputs: [cumulativeInput],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first?.totalCost == 7)
        let allTime = SpendDashboardModel.build(
            inputs: [cumulativeInput],
            requestedDays: SpendDashboardSource.scanDays,
            now: Self.now,
            calendar: Self.calendar)
        #expect(allTime.requestedDays == SpendDashboardSource.scanDays)
        #expect(allTime.groups.first?.totalCost == 15)
        #expect(allTime.groups.first?.coveredDayCount == SpendDashboardSource.scanDays)

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

        #expect(group.totalCost == 4)
        #expect(group.totalTokens == 10)
        #expect(group.hasPartialCost)
        #expect(group.hasPartialTokens)
        #expect(group.pricedProviderCount == 1)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.provider) == [.claude])
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [4])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardGroupTokenText(group).hasPrefix("~"))
            #expect(spendDashboardHistoryCaption(group, requestedDays: 7).contains("Partial estimate"))
        }
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
        #expect(group.totalTokens == 20)
        #expect(group.hasPartialTokens)
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
        #expect(group.totalTokens == 2)
        #expect(group.hasPartialTokens)
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
    func `unpriced history keeps spend unavailable and lists named models`() throws {
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
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [nil])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
    }

    @Test(CodexCredentialFixtures())
    func `Codex requests freeze source home auth and cache identity`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let home = CodexCredentialFixtures.root
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
        #expect(SpendDashboardSource.scanDays == SpendDashboardSource.activityDays)
        #expect(SpendDashboardSource.scanDays == 365)
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
        let rebucketedRequest = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: request.homePath,
            providerName: "Codex",
            index: 1,
            count: 2,
            bucketTimeZoneIdentifier: "Pacific/Kiritimati"))
        #expect(rebucketedRequest.cacheIdentity != request.cacheIdentity)

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
}

extension SpendDashboardModelTests {
    @Test
    func `partially attributed Codex history retains its priced model rows`() throws {
        let codex = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entry(day: "2026-07-15", cost: 2, model: "gpt-5.2-codex"),
                    Self.entry(day: "2026-07-16", cost: 3, model: nil),
                ]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [codex],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 5)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.modelName) == ["gpt-5.2-codex"])
        #expect(group.models.map(\.totalCost) == [2])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
    }

    @Test
    func `unpriced Codex routing row retains priced model rows as partial`() throws {
        let codex = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entryWithBreakdowns(
                        day: "2026-07-15",
                        totalCost: 2,
                        totalTokens: 100,
                        breakdowns: [
                            .init(modelName: "example-priced-codex-model", costUSD: 2, totalTokens: 40),
                            .init(modelName: "codex-auto-review", costUSD: nil, totalTokens: 60),
                        ]),
                ]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [codex],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 2)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.first(where: { $0.modelName == "example-priced-codex-model" })?.totalCost == 2)
        #expect(group.models.first(where: { $0.modelName == "codex-auto-review" })?.totalCost == nil)
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
    }

    @Test
    func `Codex history with only unpriced routing rows stays unavailable`() throws {
        let codex = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entryWithBreakdowns(
                        day: "2026-07-15",
                        totalCost: 2,
                        totalTokens: 100,
                        breakdowns: [
                            .init(modelName: "codex-auto-review", costUSD: nil, totalTokens: 100),
                        ]),
                ]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [codex],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 2)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(group) == .unavailable)
    }

    @Test
    func `partial Codex model history rejects a malformed named cost`() throws {
        let codex = SpendDashboardModel.ProviderInput(
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entryWithBreakdowns(
                        day: "2026-07-15",
                        totalCost: 2,
                        totalTokens: 100,
                        breakdowns: [
                            .init(modelName: "example-priced-codex-model", costUSD: 2, totalTokens: 40),
                            .init(modelName: "example-invalid-codex-model", costUSD: -1, totalTokens: 60),
                        ]),
                ]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [codex],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 2)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `full 30 day coverage keeps unpriced spend unavailable instead of zero`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-16", cost: nil, tokens: 12, model: nil),
                Self.entry(day: "2026-07-15", cost: nil, tokens: 8, model: nil),
            ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 30)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 20)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(group) == .unavailable)
    }

    @Test
    func `full 30 day coverage keeps empty and known zero spend distinct from unavailable`() throws {
        let unpriced = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: nil, tokens: 12, model: nil)]))],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let empty = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 0,
                last30DaysCostUSD: 0,
                currencyCode: "USD",
                historyDays: 30,
                daily: [],
                updatedAt: Self.now))],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let knownZero = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entry(day: "2026-07-16", cost: 0, tokens: 0, model: nil),
                    Self.entry(day: "2026-07-15", cost: 0, tokens: 0, model: nil),
                ]))],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        for model in [unpriced, empty, knownZero] {
            let group = try #require(model.groups.first)
            #expect(group.coveredDayCount == 30)
        }

        let unpricedGroup = try #require(unpriced.groups.first)
        #expect(unpricedGroup.totalCost == nil)
        #expect(unpricedGroup.modelHistoryCompleteness == .incomplete)
        #expect(unpricedGroup.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(unpricedGroup) == .unavailable)

        let emptyGroup = try #require(empty.groups.first)
        #expect(emptyGroup.totalCost == 0)
        #expect(emptyGroup.totalTokens == 0)
        #expect(emptyGroup.modelHistoryCompleteness == .complete)
        #expect(emptyGroup.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(emptyGroup) == .empty)

        let knownZeroGroup = try #require(knownZero.groups.first)
        #expect(knownZeroGroup.totalCost == 0)
        #expect(knownZeroGroup.totalTokens == 0)
        #expect(knownZeroGroup.modelHistoryCompleteness == .complete)
        #expect(knownZeroGroup.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(knownZeroGroup) == .empty)
    }

    @Test
    func `token mix keeps missing classes unset and supports a 90 day window`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let input = SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: 12,
                last30DaysCostUSD: 1,
                currencyCode: "USD",
                historyDays: 90,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-07-16",
                        inputTokens: 10,
                        outputTokens: 2,
                        cacheReadTokens: nil,
                        reasoningTokens: 3,
                        totalTokens: 12,
                        costUSD: 1,
                        modelsUsed: ["gpt-5.4"],
                        modelBreakdowns: [
                            .init(modelName: "gpt-5.4", costUSD: 1, totalTokens: 12, reasoningTokens: 3),
                        ]),
                ],
                sessions: [
                    CostUsageSessionBreakdown(
                        sessionID: "s1",
                        lastActivity: now,
                        inputTokens: 10,
                        cachedInputTokens: nil,
                        outputTokens: 2,
                        reasoningTokens: 3,
                        totalTokens: 12,
                        requestCount: 1,
                        costUSD: 1,
                        modelBreakdowns: []),
                ],
                updatedAt: now))
        let model = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 90,
            now: now,
            calendar: calendar)
        #expect(model.requestedDays == 90)
        let group = model.groups[0]
        #expect(group.tokenMix.inputTokens == 10)
        #expect(group.tokenMix.outputTokens == 2)
        #expect(group.tokenMix.cacheReadTokens == nil)
        #expect(group.tokenMix.reasoningTokens == 3)
        #expect(group.displayedModels.count == 1)
        #expect(group.sessions.count == 1)
        #expect(group.provenance == .listPriceEstimate)
    }

    @Test
    func `stored day keys stay put when the display timezone changes`() throws {
        let now = Date(timeIntervalSince1970: 1_784_222_400) // 2026-07-16 12:00:00 UTC
        let input = SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 4, tokens: 12)],
                updatedAt: now))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let west = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: now,
            calendar: losAngeles)
        let east = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: now,
            calendar: shanghai)
        let westDays = west.groups[0].dailyPoints.map {
            CostUsageLocalDay.key(from: $0.day, calendar: losAngeles)
        }
        let eastDays = east.groups[0].dailyPoints.map {
            CostUsageLocalDay.key(from: $0.day, calendar: shanghai)
        }
        #expect(westDays == ["2026-07-16"])
        #expect(eastDays == ["2026-07-16"])
        #expect(west.groups[0].totalCost == east.groups[0].totalCost)
    }

    @Test
    func `openCodex stays on a separate ledger from native Codex`() {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let native = SpendDashboardModel.ProviderInput(
            id: "codex:main",
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(currency: "USD", entries: [Self.entry(day: "2026-07-16", cost: 4)]),
            sourceKind: .native)
        let openCodex = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: Self.snapshot(currency: "USD", entries: [Self.entry(day: "2026-07-16", cost: 9)]),
            sourceKind: .openCodex)
        let sideBySide = SpendDashboardModel.build(
            inputs: [native, openCodex],
            requestedDays: 7,
            now: now)
        #expect(Set(sideBySide.groups[0].providers.map(\.id)) == ["opencodex", "codex:main"])
        #expect(sideBySide.groups[0].providers.count == 2)

        let hiddenNative = SpendDashboardModel.build(
            inputs: [native, openCodex],
            requestedDays: 7,
            now: now,
            hideNativeCodexWhenOpenCodexPresent: true)
        #expect(hiddenNative.groups[0].providers.map(\.id) == [SpendDashboardModel.openCodexSourceID])

        let filtered = SpendDashboardModel.build(
            inputs: [native, openCodex],
            requestedDays: 7,
            now: now,
            hiddenSourceIDs: [SpendDashboardModel.openCodexSourceID])
        #expect(filtered.groups[0].providers.map(\.id) == ["codex:main"])
        #expect(Set(filtered.availableSources.map(\.id)) == ["codex:main", SpendDashboardModel.openCodexSourceID])
    }

    @Test
    func `metered spend stays on the snapshot window instead of a shorter range`() {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 1,
            last30DaysTokens: 100,
            last30DaysCostUSD: 10,
            historyDays: 30,
            meteredCostUSD: 4.5,
            costProvenance: .mixed,
            daily: [Self.entry(day: "2026-07-16", cost: 1)],
            updatedAt: now)
        let input = SpendDashboardModel.ProviderInput(
            id: "cursor",
            provider: .cursor,
            displayName: "Cursor",
            snapshot: snapshot)
        let week = SpendDashboardModel.build(inputs: [input], requestedDays: 7, now: now)
        let month = SpendDashboardModel.build(inputs: [input], requestedDays: 30, now: now)
        #expect(week.groups[0].meteredCost == nil)
        #expect(month.groups[0].meteredCost == 4.5)
    }

    @Test
    func `vendor reported daily spend keeps vendor metered provenance`() throws {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 3.5,
            costProvenance: .vendorMetered,
            daily: [Self.entry(day: "2026-07-16", cost: 3.5)],
            updatedAt: Self.now)
        let input = SpendDashboardModel.ProviderInput(
            provider: .openrouter,
            displayName: "OpenRouter",
            snapshot: snapshot)

        let model = SpendDashboardModel.build(inputs: [input], requestedDays: 30, now: Self.now)
        let group = try #require(model.groups.first)

        #expect(group.totalCost == 3.5)
        #expect(group.provenance == .vendorMetered)
        #expect(group.meteredCost == nil)
    }

    @Test
    func `hourly points come from request buckets instead of session last activity`() {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let firstHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let secondHour = calendar.date(byAdding: .hour, value: 1, to: firstHour) ?? firstHour
        let openCodex = SpendDashboardModel.ProviderInput(
            id: SpendDashboardModel.openCodexSourceID,
            provider: .codex,
            displayName: "OpenCodex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: 17,
                sessionCostUSD: 2,
                last30DaysTokens: 17,
                last30DaysCostUSD: 2,
                historyDays: 7,
                costProvenance: .listPriceEstimate,
                daily: [Self.entry(day: "2026-07-16", cost: 2, tokens: 17)],
                sessions: [
                    CostUsageSessionBreakdown(
                        sessionID: "chat-1",
                        lastActivity: secondHour,
                        inputTokens: 14,
                        cachedInputTokens: nil,
                        outputTokens: 3,
                        totalTokens: 17,
                        requestCount: 2,
                        costUSD: 2,
                        modelBreakdowns: []),
                ],
                hourly: [
                    CostUsageHourlyEntry(hour: firstHour, totalTokens: 12, costUSD: 1.2),
                    CostUsageHourlyEntry(hour: secondHour, totalTokens: 5, costUSD: 0.8),
                ],
                updatedAt: now),
            sourceKind: .openCodex)
        let native = SpendDashboardModel.ProviderInput(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: 40,
                sessionCostUSD: 3,
                last30DaysTokens: 40,
                last30DaysCostUSD: 3,
                historyDays: 7,
                costProvenance: .listPriceEstimate,
                daily: [Self.entry(day: "2026-07-16", cost: 3, tokens: 40)],
                sessions: [
                    CostUsageSessionBreakdown(
                        sessionID: "native-1",
                        lastActivity: secondHour,
                        inputTokens: 30,
                        cachedInputTokens: nil,
                        outputTokens: 10,
                        totalTokens: 40,
                        requestCount: 1,
                        costUSD: 3,
                        modelBreakdowns: []),
                ],
                updatedAt: now))
        let combined = SpendDashboardModel.build(
            inputs: [openCodex, native],
            requestedDays: 7,
            now: now,
            calendar: calendar)
        #expect(combined.groups[0].hourlyPoints.map(\.hour) == [firstHour, secondHour])
        #expect(combined.groups[0].hourlyPoints.map(\.cost) == [1.2, 0.8])
        #expect(Set(combined.groups[0].hourlyPoints.map(\.sourceID)) == [SpendDashboardModel.openCodexSourceID])

        let selected = SpendDashboardModel.build(
            inputs: [openCodex],
            requestedDays: 7,
            now: now,
            calendar: calendar,
            selectedDay: calendar.startOfDay(for: now))
        #expect(selected.groups[0].hourlyPoints.count == 2)
        #expect(selected.groups[0].hourlyChartDomain?.lowerBound == calendar.startOfDay(for: now))
        #expect(combined.groups[0].timeZone == calendar.timeZone)
    }
}

extension SpendDashboardModelTests {
    @Test
    func `project rows aggregate windowed entries and rank by cost`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [
                            Self.entry(day: "2026-07-15", cost: 30),
                            Self.entry(day: "2026-07-16", cost: 10),
                        ],
                        projects: [
                            Self.project(name: "alpha", days: [
                                ("2026-07-15", 20),
                                ("2026-07-16", 5),
                            ]),
                            Self.project(name: "beta", days: [
                                ("2026-07-16", 10),
                            ]),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 2)
        #expect(group.projects[0].projectName == "alpha")
        #expect(group.projects[0].rank == 1)
        #expect(group.projects[0].totalCost == 25)
        #expect(group.projects[0].totalTokens == 20)
        #expect(group.projects[0].path == "/tmp/alpha")
        #expect(group.projects[1].projectName == "beta")
        #expect(group.projects[1].rank == 2)
        #expect(group.projects[1].totalCost == 10)
        #expect(group.projects[1].totalTokens == 10)
    }

    @Test
    func `project rows exclude days outside the requested window`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [Self.entry(day: "2026-07-15", cost: 3)],
                        projects: [
                            Self.project(name: "alpha", days: [
                                ("2026-07-01", 100),
                                ("2026-07-15", 3),
                            ]),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 1)
        #expect(group.projects[0].totalCost == 3)
        #expect(group.projects[0].totalTokens == 10)
    }

    @Test
    func `project rows stay attributed per source`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex · #1",
                    snapshot: Self.snapshot(
                        currency: "USD",
                        entries: [Self.entry(day: "2026-07-15", cost: 5)],
                        projects: [Self.project(name: "shared", days: [("2026-07-15", 5)])])),
                SpendDashboardModel.ProviderInput(
                    id: "codex-b",
                    provider: .codex,
                    displayName: "Codex · #2",
                    snapshot: Self.snapshot(
                        currency: "USD",
                        entries: [Self.entry(day: "2026-07-15", cost: 7)],
                        projects: [Self.project(name: "shared", days: [("2026-07-15", 7)])])),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 2)
        #expect(group.projects.map(\.totalCost) == [7, 5])
        #expect(Set(group.projects.map(\.id)) == ["codex-a:shared", "codex-b:shared"])
        #expect(group.projects[0].providerName == "Codex · #2")
    }

    @Test
    func `project rows drop projects without attributable window days`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [Self.entry(day: "2026-07-15", cost: 1)],
                        projects: [
                            Self.project(name: "stale", days: [("2026-05-01", 50)]),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.isEmpty)
    }

    @Test
    func `project rows report unknown aggregates as nil but keep known ones`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [Self.entry(day: "2026-07-15", cost: 9)],
                        projects: [
                            Self.project(name: "unknown-cost", days: [
                                ("2026-07-15", 4),
                                ("2026-07-16", nil),
                            ]),
                            Self.project(
                                name: "unknown-tokens",
                                days: [("2026-07-15", 4)],
                                tokens: nil),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 2)
        let unknownCost = try #require(group.projects.first { $0.projectName == "unknown-cost" })
        #expect(unknownCost.totalCost == nil)
        #expect(unknownCost.totalTokens == 20)
        let unknownTokens = try #require(group.projects.first { $0.projectName == "unknown-tokens" })
        #expect(unknownTokens.totalCost == 4)
        #expect(unknownTokens.totalTokens == nil)
    }

    private static func project(
        name: String,
        days: [(String, Double?)],
        tokens: Int? = 10) -> CostUsageProjectBreakdown
    {
        CostUsageProjectBreakdown(
            name: name,
            path: "/tmp/\(name)",
            totalTokens: nil,
            totalCostUSD: nil,
            daily: days.map { day, cost in
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            modelBreakdowns: nil)
    }
}

extension SpendDashboardModelTests {
    /// Shared fixture helpers for dashboard model tests.
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
        projects: [CostUsageProjectBreakdown] = [],
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
            projects: projects,
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
