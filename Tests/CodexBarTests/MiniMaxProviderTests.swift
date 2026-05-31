import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxAPISettingsReaderTests {
    @Test
    func `api token prefers coding plan specific environment key`() {
        let token = MiniMaxAPISettingsReader.apiToken(environment: [
            "MINIMAX_API_KEY": "sk-api-standard",
            "MINIMAX_CODING_API_KEY": "sk-cp-coding-plan",
        ])

        #expect(token == "sk-cp-coding-plan")
        #expect(MiniMaxAPISettingsReader.apiKeyKind(token: token) == .codingPlan)
    }

    @Test
    func `api token falls back to generic environment key`() {
        let token = MiniMaxAPISettingsReader.apiToken(environment: [
            "MINIMAX_API_KEY": "\"sk-api-standard\"",
        ])

        #expect(token == "sk-api-standard")
        #expect(MiniMaxAPISettingsReader.apiKeyKind(token: token) == .standard)
    }
}

struct MiniMaxSettingsReaderTests {
    @Test
    func `URL overrides infer HTTPS scheme`() {
        let url = MiniMaxSettingsReader.codingPlanURL(environment: [
            MiniMaxSettingsReader.codingPlanURLKey: "platform.minimax.test/account",
        ])

        #expect(url?.scheme == "https")
        #expect(url?.host == "platform.minimax.test")
    }

    @Test
    func `URL overrides reject non HTTPS schemes`() {
        let httpURL = MiniMaxSettingsReader.remainsURL(environment: [
            MiniMaxSettingsReader.remainsURLKey: "http://platform.minimax.test/remains",
        ])
        let ftpURL = MiniMaxSettingsReader.billingHistoryURL(environment: [
            MiniMaxSettingsReader.billingHistoryURLKey: "ftp://platform.minimax.test/billing",
        ])

        #expect(httpURL == nil)
        #expect(ftpURL == nil)
    }

    @Test
    func `host override rejects non HTTPS schemes`() {
        let httpHost = MiniMaxSettingsReader.hostOverride(environment: [
            MiniMaxSettingsReader.hostKey: "http://platform.minimax.test",
        ])
        let httpsHost = MiniMaxSettingsReader.hostOverride(environment: [
            MiniMaxSettingsReader.hostKey: "https://platform.minimax.test",
        ])
        let bareHost = MiniMaxSettingsReader.hostOverride(environment: [
            MiniMaxSettingsReader.hostKey: "platform.minimax.test",
        ])

        #expect(httpHost == nil)
        #expect(httpsHost == "https://platform.minimax.test")
        #expect(bareHost == "platform.minimax.test")
    }

    @Test
    func `validation fails closed for explicit non HTTPS endpoint overrides`() throws {
        let rejectedOverrides = [
            MiniMaxSettingsReader.codingPlanURLKey: "http://platform.minimax.test/account",
            MiniMaxSettingsReader.remainsURLKey: "http://platform.minimax.test/remains",
            MiniMaxSettingsReader.billingHistoryURLKey: "ftp://platform.minimax.test/history",
            MiniMaxSettingsReader.hostKey: "http://platform.minimax.test",
        ]

        for (key, value) in rejectedOverrides {
            #expect(throws: MiniMaxSettingsError.invalidEndpointOverride(key)) {
                try MiniMaxSettingsReader.validateEndpointOverrides(environment: [key: value])
            }
        }

        try MiniMaxSettingsReader.validateEndpointOverrides(environment: [
            MiniMaxSettingsReader.codingPlanURLKey: "https://platform.minimax.test/account",
            MiniMaxSettingsReader.remainsURLKey: "https://platform.minimax.test/remains",
            MiniMaxSettingsReader.billingHistoryURLKey: "https://platform.minimax.test/history",
            MiniMaxSettingsReader.hostKey: "platform.minimax.test",
        ])
    }
}

struct MiniMaxProviderStrategyTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `browser cookie import is user initiated app only`() {
        let appContext = self.makeContext(runtime: .app)
        let cliContext = self.makeContext(runtime: .cli)

        #expect(MiniMaxCodingPlanFetchStrategy.allowsBrowserCookieImport(context: appContext) == false)
        #expect(MiniMaxCodingPlanFetchStrategy.allowsBrowserCookieImport(context: cliContext) == false)

        ProviderInteractionContext.$current.withValue(.userInitiated) {
            #expect(MiniMaxCodingPlanFetchStrategy.allowsBrowserCookieImport(context: appContext))
            #expect(MiniMaxCodingPlanFetchStrategy.allowsBrowserCookieImport(context: cliContext) == false)
        }
    }

    @Test
    func `web strategy rejects invalid endpoint override before browser credential discovery`() async {
        let context = self.makeContext(
            runtime: .app,
            env: [MiniMaxSettingsReader.remainsURLKey: "http://localhost:8080/remains"])

        await #expect(throws: MiniMaxSettingsError.invalidEndpointOverride(MiniMaxSettingsReader.remainsURLKey)) {
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await MiniMaxCodingPlanFetchStrategy().fetch(context)
            }
        }
    }

    private func makeContext(runtime: ProviderRuntime, env: [String: String] = [:]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: runtime,
            sourceMode: .web,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

struct MiniMaxCookieHeaderTests {
    @Test
    func `normalizes raw cookie header`() {
        let raw = "foo=bar; session=abc123"
        let normalized = MiniMaxCookieHeader.normalized(from: raw)
        #expect(normalized == "foo=bar; session=abc123")
    }

    @Test
    func `extracts from cookie header line`() {
        let raw = "Cookie: foo=bar; session=abc123"
        let normalized = MiniMaxCookieHeader.normalized(from: raw)
        #expect(normalized == "foo=bar; session=abc123")
    }

    @Test
    func `extracts from curl header`() {
        let raw = "curl https://platform.minimax.io -H 'Cookie: foo=bar; session=abc123' -H 'accept: */*'"
        let normalized = MiniMaxCookieHeader.normalized(from: raw)
        #expect(normalized == "foo=bar; session=abc123")
    }

    @Test
    func `extracts from curl cookie flag`() {
        let raw = "curl https://platform.minimax.io --cookie 'foo=bar; session=abc123'"
        let normalized = MiniMaxCookieHeader.normalized(from: raw)
        #expect(normalized == "foo=bar; session=abc123")
    }

    @Test
    func `extracts auth and group ID from curl`() {
        let raw = """
        curl 'https://platform.minimax.io/v1/api/openplatform/coding_plan/remains?GroupId=123456' \
          -H 'authorization: Bearer token123' \
          -H 'Cookie: foo=bar; session=abc123'
        """
        let override = MiniMaxCookieHeader.override(from: raw)
        #expect(override?.cookieHeader == "foo=bar; session=abc123")
        #expect(override?.authorizationToken == "token123")
        #expect(override?.groupID == "123456")
    }

    @Test
    func `extracts auth from uppercase header`() {
        let raw = """
        curl 'https://platform.minimax.io/v1/api/openplatform/coding_plan/remains?GROUP_ID=98765' \
          -H 'Authorization: Bearer token-abc' \
          -H 'Cookie: foo=bar; session=abc123'
        """
        let override = MiniMaxCookieHeader.override(from: raw)
        #expect(override?.authorizationToken == "token-abc")
        #expect(override?.groupID == "98765")
    }
}

struct MiniMaxUsageParserTests {
    @Test
    func `signed out check ignores login copy inside scripts`() {
        let html = """
        <html>
          <head>
            <script id="__NEXT_DATA__" type="application/json">
              {
                "props": {
                  "pageProps": {
                    "_nextI18Next": {
                      "initialI18nStore": {
                        "zh": {
                          "common": {
                            "landing_common_login": "登录",
                            "login": "Log in"
                          }
                        }
                      }
                    }
                  }
                }
              }
            </script>
          </head>
          <body><div id="__next">Coding Plan</div></body>
        </html>
        """

        #expect(!MiniMaxUsageFetcher._looksSignedOutForTesting(html: html))
    }

    @Test
    func `signed out check still detects visible login copy`() {
        let html = """
        <html>
          <head><script>{"landing_common_login":"登录"}</script></head>
          <body><main><a>Log in</a></main></body>
        </html>
        """

        #expect(MiniMaxUsageFetcher._looksSignedOutForTesting(html: html))
    }

    @Test
    func `parses planName from concrete fields in remains response`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. plan_name
        let jsonPlanName = """
        {
          "base_resp": { "status_code": 0 },
          "plan_name": "MiniMax Star",
          "model_remains": [{"model_name": "abab6.5"}]
        }
        """
        let snapshot1 = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(jsonPlanName.utf8), now: now)
        #expect(snapshot1.planName == "MiniMax Star")

        // 2. current_plan_title
        let jsonCurrentPlan = """
        {
          "base_resp": { "status_code": 0 },
          "current_plan_title": "Coding Plan Pro",
          "model_remains": [{"model_name": "abab6.5"}]
        }
        """
        let snapshot2 = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(jsonCurrentPlan.utf8), now: now)
        #expect(snapshot2.planName == "Coding Plan Pro")

        // 3. current_subscribe_title
        let jsonSubscribe = """
        {
          "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [{"model_name": "abab6.5"}]
        }
        """
        let snapshot3 = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(jsonSubscribe.utf8), now: now)
        #expect(snapshot3.planName == "Max")

        // 4. combo_title
        let jsonCombo = """
        {
          "base_resp": { "status_code": 0 },
          "combo_title": "Combo Star",
          "model_remains": [{"model_name": "abab6.5"}]
        }
        """
        let snapshot4 = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(jsonCombo.utf8), now: now)
        #expect(snapshot4.planName == "Combo Star")

        // 5. current_combo_card.title
        let jsonComboCard = """
        {
          "base_resp": { "status_code": 0 },
          "current_combo_card": { "title": "Card Title" },
          "model_remains": [{"model_name": "abab6.5"}]
        }
        """
        let snapshot5 = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(jsonComboCard.utf8), now: now)
        #expect(snapshot5.planName == "Card Title")
    }

    @Test
    func `toUsageSnapshot maps planName to loginMethod`() {
        let now = Date()
        let snapshot1 = MiniMaxUsageSnapshot(
            planName: "MiniMax Star",
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now)
        let usage1 = snapshot1.toUsageSnapshot()
        #expect(usage1.identity?.loginMethod == "MiniMax Star")

        let snapshot2 = MiniMaxUsageSnapshot(
            planName: nil,
            availablePrompts: nil,
            currentPrompts: nil,
            remainingPrompts: nil,
            windowMinutes: nil,
            usedPercent: nil,
            resetsAt: nil,
            updatedAt: now)
        let usage2 = snapshot2.toUsageSnapshot()
        #expect(usage2.identity?.loginMethod == nil)
    }

    @Test
    func `parses coding plan snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let html = """
        <div>Coding Plan</div>
        <div>Max</div>
        <div>Available usage: 1,000 prompts / 5 hours</div>
        <div>Current Usage</div>
        <div>0% Used</div>
        <div>Resets in 4 min</div>
        """

        let snapshot = try MiniMaxUsageParser.parse(html: html, now: now)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1000)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.usedPercent == 0)
        #expect(snapshot.resetsAt == now.addingTimeInterval(240))

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.resetDescription == "1000 prompts / 5 hours")
    }

    @Test
    func `parses coding plan remains response`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [
            {
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "remains_time": 240000
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let expectedReset = Date(timeIntervalSince1970: TimeInterval(end) / 1000)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1000)
        #expect(snapshot.currentPrompts == 750)
        #expect(snapshot.remainingPrompts == 250)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.usedPercent == 75)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `parses model remains services using used quota semantics`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "current_subscribe_title": "Max",
          "model_remains": [
            {
              "model_name": "M2.7-highspeed",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "remains_time": 240000
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let service = try #require(snapshot.services?.first)

        #expect(service.displayName == "Text Generation")
        #expect(service.usage == 750)
        #expect(service.remaining == 250)
        #expect(service.limit == 1000)
        #expect(service.percent == 75)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 75)
    }

    @Test
    func `text generation includes weekly window when provided`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let weekStart = start - 2 * 24 * 60 * 60 * 1000
        let weekEnd = weekStart + 7 * 24 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "MiniMax-M1",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "current_weekly_total_count": 6000,
              "current_weekly_usage_count": 5376,
              "weekly_start_time": \(weekStart),
              "weekly_end_time": \(weekEnd)
            }
          ]
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)
        #expect(services.count == 2)
        #expect(services[0].serviceType == "Text Generation")
        #expect(services[0].windowType == "5 hours")
        #expect(services[1].serviceType == "Text Generation")
        #expect(services[1].windowType == "Weekly")
        #expect(services[1].usage == 624)
        #expect(services[1].limit == 6000)
        #expect(services[1].timeRange.contains("/"))
        #expect(services[1].timeRange.contains("UTC+8"))
        #expect(!services[1].timeRange.hasPrefix("10:00-10:00"))
    }

    @Test
    func `legacy plan hides weekly when weekly total is missing or zero`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "model_remains": [
            {
              "model_name": "MiniMax-M1",
              "current_interval_total_count": 1000,
              "current_interval_usage_count": 250,
              "start_time": \(start),
              "end_time": \(end),
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0
            }
          ]
        }
        """
        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)
        #expect(services.count == 1)
        #expect(services[0].windowType == "5 hours")
    }

    @Test
    func `parses multi service payload and utc offset reset`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 25,
            hour: 11,
            minute: 0)))
        let expectedReset = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 25,
            hour: 15,
            minute: 0)))
        let json = """
        {
          "data": {
            "services": [
              {
                "service_type": "Text Generation",
                "window_type": "5 hours",
                "time_range": "10:00-15:00(UTC+8)",
                "usage": 2,
                "limit": 10
              },
              {
                "service_type": "Image",
                "window_type": "Today",
                "time_range": "2026/03/25 00:00 - 2026/03/26 00:00",
                "usage": "5",
                "limit": "50",
                "percent": "10"
              }
            ]
          }
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)

        #expect(services.count == 2)
        #expect(services[0].usage == 2)
        #expect(services[0].remaining == 8)
        #expect(services[0].percent == 20)
        #expect(services[0].resetsAt == expectedReset)
        #expect(services[1].usage == 5)
        #expect(services[1].remaining == 45)
        #expect(services[1].percent == 10)
    }

    @Test
    func `parses coding plan remains from data wrapper`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "base_resp": { "status_code": "0" },
          "data": {
            "current_subscribe_title": "Max",
            "model_remains": [
              {
                "current_interval_total_count": "15000",
                "current_interval_usage_count": "14989",
                "start_time": \(start),
                "end_time": \(end),
                "remains_time": 8941292
              }
            ]
          }
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let expectedUsed = Double(11) / Double(15000) * 100
        let expectedReset = Date(timeIntervalSince1970: TimeInterval(end) / 1000)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 15000)
        #expect(snapshot.currentPrompts == 11)
        #expect(snapshot.remainingPrompts == 14989)
        #expect(snapshot.windowMinutes == 300)
        #expect(abs((snapshot.usedPercent ?? 0) - expectedUsed) < 0.01)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `parses coding plan from next data`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = 1_700_000_000_000
        let end = start + 5 * 60 * 60 * 1000
        let json = """
        {
          "props": {
            "pageProps": {
              "data": {
                "base_resp": { "status_code": 0 },
                "current_subscribe_title": "Max",
                "model_remains": [
                  {
                    "current_interval_total_count": 1000,
                    "current_interval_usage_count": 250,
                    "start_time": \(start),
                    "end_time": \(end),
                    "remains_time": 240000
                  }
                ]
              }
            }
          }
        }
        """
        let html = """
        <html>
          <script id="__NEXT_DATA__" type="application/json">\(json)</script>
        </html>
        """

        let snapshot = try MiniMaxUsageParser.parse(html: html, now: now)
        let expectedReset = Date(timeIntervalSince1970: TimeInterval(end) / 1000)

        #expect(snapshot.planName == "Max")
        #expect(snapshot.availablePrompts == 1000)
        #expect(snapshot.currentPrompts == 750)
        #expect(snapshot.remainingPrompts == 250)
        #expect(snapshot.windowMinutes == 300)
        #expect(snapshot.usedPercent == 75)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `parses HTML with used prefix and reset time`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 10, minute: 0)))
        let expectedReset = try #require(calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 23,
            minute: 30)))

        let html = """
        <div>Coding Plan Pro</div>
        <div>Available usage: 1,500 prompts / 1.5 hours</div>
        <div>Used 75%</div>
        <div>Resets at 23:30 (UTC)</div>
        """

        let snapshot = try MiniMaxUsageParser.parse(html: html, now: now)

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.availablePrompts == 1500)
        #expect(snapshot.windowMinutes == 90)
        #expect(snapshot.usedPercent == 75)
        #expect(snapshot.resetsAt == expectedReset)
    }

    @Test
    func `throws on missing cookie response`() {
        let json = """
        {
          "base_resp": { "status_code": 1004, "status_msg": "cookie is missing, log in again" }
        }
        """

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8))
        }
    }

    @Test
    func `throws on string status code when logged out`() {
        let json = """
        {
          "base_resp": { "status_code": "1004", "status_msg": "login required" }
        }
        """

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8))
        }
    }

    @Test
    func `throws on error in data wrapper`() {
        let json = """
        {
          "data": {
            "base_resp": { "status_code": 1004, "status_msg": "unauthorized" }
          }
        }
        """

        #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8))
        }
    }

    @Test
    func `billing history aggregates records locally`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "consume_token_sum": 999999,
          "total_cnt": 4,
          "charge_records": [
            {
              "consume_token": 1000,
              "consume_cash_after_voucher": 1.25,
              "ymd": "2026-05-17",
              "method": "chat",
              "model": "MiniMax-M1"
            },
            {
              "consume_token": "2000",
              "consume_cash": "2.50",
              "ymd": "2026-05-16",
              "method": "chat",
              "model": "MiniMax-M2"
            },
            {
              "consume_input_token": 1200,
              "consume_output_token": 1800,
              "ymd": "2026-04-18",
              "method": "audio",
              "model": "speech-2.8"
            },
            {
              "consume_token": 4000,
              "ymd": "2026-04-17",
              "method": "old",
              "model": "ignored"
            }
          ]
        }
        """

        let summary = try MiniMaxBillingHistoryParser.parse(
            data: Data(json.utf8),
            now: now,
            calendar: calendar)

        #expect(summary.todayTokens == 1000)
        #expect(summary.last30DaysTokens == 6000)
        #expect(summary.todayCash == 1.25)
        #expect(summary.last30DaysCash == 3.75)
        #expect(summary.daily.map(\.day) == ["2026-04-18", "2026-05-16", "2026-05-17"])
        #expect(summary.topMethods.first?.name == "audio")
        #expect(summary.topModels.first?.name == "speech-2.8")
    }

    @Test
    func `billing history preserves date only days in local calendar`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: -7 * 60 * 60))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "total_cnt": 1,
          "charge_records": [
            {
              "consume_token": 1234,
              "ymd": "2026-05-17",
              "method": "chat",
              "model": "MiniMax-M1"
            }
          ]
        }
        """

        let summary = try MiniMaxBillingHistoryParser.parse(
            data: Data(json.utf8),
            now: now,
            calendar: calendar)

        #expect(summary.todayTokens == 1234)
        #expect(summary.daily.map(\.day) == ["2026-05-17"])
    }

    @Test
    func `billing history filters failed records`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let json = """
        {
          "base_resp": { "status_code": 0 },
          "total_cnt": 5,
          "charge_records": [
            {
              "consume_token": 1000,
              "ymd": "2026-05-17",
              "method": "chat",
              "model": "MiniMax-M1",
              "result": "SUCCESS"
            },
            {
              "consume_token": 2000,
              "ymd": "2026-05-17",
              "method": "chat",
              "model": "MiniMax-M1",
              "result": "FAILED"
            },
            {
              "consume_token": 3000,
              "ymd": "2026-05-17",
              "method": "chat",
              "model": "MiniMax-M1",
              "status": "fail"
            },
            {
              "consume_token": 4000,
              "ymd": "2026-05-17",
              "method": "audio",
              "model": "speech-2.8"
            },
            {
              "consume_token": 5000,
              "ymd": "2026-05-17",
              "method": "video",
              "model": "video-1",
              "status": 0
            }
          ]
        }
        """

        let summary = try MiniMaxBillingHistoryParser.parse(
            data: Data(json.utf8),
            now: now,
            calendar: calendar)

        // Only SUCCESS (1000) and missing/empty result status (4000) should be included.
        // FAILED (2000), status "fail" (3000), and numeric status 0 (5000) should be skipped.
        #expect(summary.todayTokens == 5000)
        #expect(summary.last30DaysTokens == 5000)
        #expect(summary.daily.map(\.day) == ["2026-05-17"])

        // Top methods should aggregate only SUCCESS/missing records.
        #expect(summary.topMethods.count == 2)
        #expect(summary.topMethods[0].name == "audio")
        #expect(summary.topMethods[0].tokens == 4000)
        #expect(summary.topMethods[1].name == "chat")
        #expect(summary.topMethods[1].tokens == 1000)
    }

    @Test
    func `web usage fetch attaches billing history when available`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: Self.codingPlanJSON,
                    contentType: "application/json")
            }
            #expect(url.path == "/account/amount")
            #expect(url.query?.contains("aggregate=false") == true)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=abc")
            let body = """
            {
              "base_resp": { "status_code": 0 },
              "total_cnt": 1,
              "charge_records": [
                {
                  "consume_token": 1234,
                  "ymd": "2026-05-17",
                  "method": "chat",
                  "model": "MiniMax-M1"
                }
              ]
            }
            """
            return Self.httpResponse(url: url, body: body, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .global,
            environment: [:],
            session: transport,
            now: now)

        #expect(snapshot.currentPrompts == 2)
        #expect(snapshot.billingSummary?.todayTokens == 1234)
        #expect(snapshot.billingSummary?.last30DaysTokens == 1234)
    }

    @Test
    func `web usage fetch keeps paginating billing history until 30 day cutoff`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: Self.codingPlanJSON,
                    contentType: "application/json")
            }
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "page" }?
                .value ?? "1"
            let recordDay = page == "3" ? "2026-04-17" : "2026-05-17"
            let records = (0..<100)
                .map { _ in
                    """
                    {"consume_token":1,"ymd":"\(recordDay)","method":"chat","model":"MiniMax-M1"}
                    """
                }
                .joined(separator: ",")
            let body = """
            {
              "base_resp": { "status_code": 0 },
              "total_cnt": 250,
              "charge_records": [\(records)]
            }
            """
            return Self.httpResponse(url: url, body: body, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .global,
            environment: [:],
            session: transport,
            now: now)

        let billingRequests = await transport.requests().filter { $0.url?.path == "/account/amount" }
        #expect(billingRequests.count == 3)
        #expect(snapshot.billingSummary?.last30DaysTokens == 200)
    }

    @Test
    func `web usage fetch skips billing history when optional usage is disabled`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path.contains("coding-plan"))
            return Self.httpResponse(
                url: url,
                body: Self.codingPlanJSON,
                contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .global,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)

        let requests = await transport.requests()
        #expect(snapshot.currentPrompts == 2)
        #expect(snapshot.billingSummary == nil)
        #expect(requests.count == 1)
    }

    @Test
    func `web usage fetch keeps quota when billing history is forbidden`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: Self.codingPlanJSON,
                    contentType: "application/json")
            }
            return Self.httpResponse(url: url, body: "{}", statusCode: 403, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .global,
            environment: [:],
            session: transport,
            now: now)

        #expect(snapshot.currentPrompts == 2)
        #expect(snapshot.billingSummary == nil)
    }

    @Test
    func `web usage fetch preserves stale bearer failure during billing history`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: Self.codingPlanJSON,
                    contentType: "application/json")
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stale")
            return Self.httpResponse(url: url, body: "{}", statusCode: 403, contentType: "application/json")
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "HERTZ-SESSION=abc",
                authorizationToken: "stale",
                region: .global,
                environment: [:],
                session: transport,
                now: now)
        }
    }

    @Test
    func `web usage fetch preserves billing history cancellation`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-17T12:00:00Z"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: Self.codingPlanJSON,
                    contentType: "application/json")
            }
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "HERTZ-SESSION=abc",
                region: .global,
                environment: [:],
                session: transport,
                now: now)
        }
    }

    private static let codingPlanJSON = """
    {
      "base_resp": { "status_code": 0 },
      "data": {
        "plan_name": "Max",
        "model_remains": [
          {
            "model_name": "MiniMax-M1",
            "current_interval_total_count": 10,
            "current_interval_usage_count": 8,
            "start_time": 1779019200,
            "end_time": 1779037200,
            "remains_time": 3600
          }
        ]
      }
    }
    """

    private static func httpResponse(
        url: URL,
        body: String,
        statusCode: Int = 200,
        contentType: String) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (Data(body.utf8), response)
    }
}

struct MiniMaxUsageFetcherSecurityTests {
    @Test
    func `web usage fetch rejects non HTTPS endpoint override before sending credentials`() async throws {
        let transport = ProviderHTTPTransportStub { _ in
            Issue.record("request should not be sent for invalid endpoint override")
            return try Self.httpResponse(
                url: #require(URL(string: "https://platform.minimax.test/unreachable")),
                body: "{}",
                contentType: "application/json")
        }

        await #expect(throws: MiniMaxSettingsError.invalidEndpointOverride(MiniMaxSettingsReader.remainsURLKey)) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "[REDACTED]",
                region: .global,
                environment: [MiniMaxSettingsReader.remainsURLKey: "http://localhost:8080/remains"],
                session: transport)
        }
        let requests = await transport.requests()
        #expect(requests.isEmpty)
    }

    private static func httpResponse(
        url: URL,
        body: String,
        statusCode: Int = 200,
        contentType: String) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (Data(body.utf8), response)
    }
}

struct MiniMaxAPIRegionTests {
    @Test
    func `defaults to global hosts`() {
        let codingPlan = MiniMaxUsageFetcher.resolveCodingPlanURL(region: .global, environment: [:])
        let remains = MiniMaxUsageFetcher.resolveRemainsURL(region: .global, environment: [:])
        #expect(codingPlan.host == "platform.minimax.io")
        #expect(remains.host == "platform.minimax.io")
    }

    @Test
    func `uses china mainland hosts`() {
        let codingPlan = MiniMaxUsageFetcher.resolveCodingPlanURL(region: .chinaMainland, environment: [:])
        let remains = MiniMaxUsageFetcher.resolveRemainsURL(region: .chinaMainland, environment: [:])
        #expect(codingPlan.host == "platform.minimaxi.com")
        #expect(remains.host == "platform.minimaxi.com")
        #expect(codingPlan.query == "cycle_type=3")
    }

    @Test
    func `host override wins for remains and coding plan`() {
        let env = [MiniMaxSettingsReader.hostKey: "api.minimaxi.com"]
        let codingPlan = MiniMaxUsageFetcher.resolveCodingPlanURL(region: .global, environment: env)
        let remains = MiniMaxUsageFetcher.resolveRemainsURL(region: .global, environment: env)
        #expect(codingPlan.host == "api.minimaxi.com")
        #expect(remains.host == "api.minimaxi.com")
    }

    @Test
    func `billing history url uses account amount endpoint`() {
        let url = MiniMaxUsageFetcher.resolveBillingHistoryURL(region: .chinaMainland, environment: [:], page: 2)
        #expect(url.host == "platform.minimaxi.com")
        #expect(url.path == "/account/amount")
        #expect(url.query?.contains("page=2") == true)
        #expect(url.query?.contains("limit=100") == true)
        #expect(url.query?.contains("aggregate=false") == true)
    }

    @Test
    func `remains url override beats host`() {
        let env = [MiniMaxSettingsReader.remainsURLKey: "https://platform.minimaxi.com/custom/remains"]
        let remains = MiniMaxUsageFetcher.resolveRemainsURL(region: .global, environment: env)
        #expect(remains.absoluteString == "https://platform.minimaxi.com/custom/remains")
    }

    @Test
    func `origin uses coding plan override host`() {
        let env = [MiniMaxSettingsReader.codingPlanURLKey: "https://api.minimaxi.com/custom/path?cycle_type=3"]
        let codingPlan = MiniMaxUsageFetcher.resolveCodingPlanURL(region: .global, environment: env)
        let origin = MiniMaxUsageFetcher.originURL(from: codingPlan)
        #expect(origin.absoluteString == "https://api.minimaxi.com")
    }

    @Test
    func `origin strips host override path`() {
        let env = [MiniMaxSettingsReader.hostKey: "https://api.minimaxi.com/custom/path"]
        let codingPlan = MiniMaxUsageFetcher.resolveCodingPlanURL(region: .global, environment: env)
        let origin = MiniMaxUsageFetcher.originURL(from: codingPlan)
        #expect(origin.absoluteString == "https://api.minimaxi.com")
    }
}
