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
