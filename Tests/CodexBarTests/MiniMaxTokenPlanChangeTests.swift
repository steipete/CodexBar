import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MiniMaxTokenPlanChangeTests {
    @Test
    func `parses percent based general token plan remains`() throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(
            data: Data(Self.percentBasedRemainsJSON.utf8),
            now: now)
        let services = try #require(snapshot.services)

        #expect(snapshot.availablePrompts == nil)
        #expect(snapshot.currentPrompts == nil)
        #expect(snapshot.remainingPrompts == nil)
        #expect(snapshot.usedPercent == 4)
        #expect(services.count == 2)
        #expect(services[0].serviceType == "general")
        #expect(services[0].displayName == "General")
        #expect(services[0].windowType == "5 hours")
        #expect(services[0].usage == 4)
        #expect(services[0].limit == 100)
        #expect(services[0].percent == 4)
        #expect(services[1].windowType == "Weekly")
        #expect(services[1].usage == 1)
        #expect(services[1].limit == 100)
        #expect(services[1].percent == 1)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 4)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 1)
        #expect(usage.secondary?.windowMinutes == 10080)
    }

    @Test
    func `zero count fields do not suppress percent based quota windows`() throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let json = """
        {
          "base_resp": { "status_code": "0" },
          "data": {
            "current_subscribe_title": "Token Plan · TokenPlanPlus-年度会员",
            "points_balance": "14000",
            "model_remains": [
              {
                "model_name": "general",
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": "96",
                "start_time": 1780279200000,
                "end_time": 1780297200000,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "current_weekly_remaining_percent": "99",
                "weekly_start_time": 1780243200000,
                "weekly_end_time": 1780848000000
              }
            ]
          }
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)

        #expect(snapshot.planName == "Token Plan · TokenPlanPlus-年度会员")
        #expect(snapshot.pointsBalance == 14000)
        #expect(snapshot.services?.count == 2)
        #expect(snapshot.toUsageSnapshot().providerCost?.used == 14000)
    }

    @Test
    func `video first token plan still uses general quota as primary and weekly secondary`() throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let json = """
        {
          "base_resp": { "status_code": "0" },
          "model_remains": [
            {
              "model_name": "video",
              "current_interval_total_count": 100,
              "current_interval_usage_count": 70,
              "current_interval_remaining_percent": 30,
              "start_time": 1780243200000,
              "end_time": 1780329600000
            },
            {
              "model_name": "general",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 96,
              "start_time": 1780279200000,
              "end_time": 1780297200000,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_remaining_percent": 99,
              "weekly_start_time": 1780243200000,
              "weekly_end_time": 1780848000000
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.services?.map(\.serviceType) == ["video", "general", "general"])
        #expect(usage.primary?.usedPercent == 4)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 1)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 70)
    }

    @Test
    func `plus token plan omits unavailable video quota lane`() throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "start_time": 1780279200000,
              "end_time": 1780297200000,
              "remains_time": 16659830,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "general",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1780243200000,
              "weekly_end_time": 1780848000000,
              "weekly_remains_time": 567459830,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 96,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 99
            },
            {
              "start_time": 1780243200000,
              "end_time": 1780329600000,
              "remains_time": 49059830,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "video",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1780243200000,
              "weekly_end_time": 1780848000000,
              "weekly_remains_time": 567459830,
              "current_interval_status": 3,
              "current_interval_remaining_percent": 100,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100
            }
          ]
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)

        #expect(snapshot.planName == "Plus")
        #expect(snapshot.toUsageSnapshot().identity?.loginMethod == "Plus")
        #expect(services.map(\.serviceType) == ["general", "general"])
        #expect(services.map(\.displayName) == ["General", "General"])
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(snapshot.toUsageSnapshot().secondary?.usedPercent == 1)
        #expect(snapshot.toUsageSnapshot().tertiary == nil)
    }

    @Test
    func `plus token plan renders boosted interval and unlimited weekly lane`() throws {
        let now = Date(timeIntervalSince1970: 1_780_347_620)
        let json = """
        {
          "model_remains": [
            {
              "start_time": 1780347600000,
              "end_time": 1780365600000,
              "remains_time": 4650822,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "general",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1780243200000,
              "weekly_end_time": 1780848000000,
              "weekly_remains_time": 487050822,
              "current_interval_status": 1,
              "current_interval_remaining_percent": 99,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100,
              "interval_boost_permill": 2000,
              "weekly_boost_permill": 2000
            },
            {
              "start_time": 1780329600000,
              "end_time": 1780416000000,
              "remains_time": 55050822,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "model_name": "video",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1780243200000,
              "weekly_end_time": 1780848000000,
              "weekly_remains_time": 487050822,
              "current_interval_status": 3,
              "current_interval_remaining_percent": 100,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100
            }
          ],
          "base_resp": { "status_code": 0, "status_msg": "success" }
        }
        """

        let snapshot = try MiniMaxUsageParser.parseCodingPlanRemains(data: Data(json.utf8), now: now)
        let services = try #require(snapshot.services)

        #expect(services.count == 2)
        #expect(services[0].serviceType == "general")
        #expect(services[0].displayName == "General")
        #expect(services[0].windowType == "5 hours")
        #expect(services[0].usage == 2)
        #expect(services[0].limit == 200)
        #expect(services[0].percent == 1)
        #expect(services[0].isUnlimited == false)
        #expect(services[1].serviceType == "general")
        #expect(services[1].displayName == "General")
        #expect(services[1].windowType == "Weekly")
        #expect(services[1].usage == 0)
        #expect(services[1].limit == 0)
        #expect(services[1].percent == 0)
        #expect(services[1].isUnlimited)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 1)
        #expect(snapshot.toUsageSnapshot().secondary?.resetDescription == "Unlimited")
    }

    @Test
    func `web usage fetch falls back to www remains host after platform parse failure`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            if url.host == "platform.minimaxi.com", url.path.contains("coding_plan/remains") {
                return Self.httpResponse(url: url, body: "not json", contentType: "application/json")
            }
            #expect(url.host == "www.minimaxi.com")
            #expect(url.path == "/v1/api/openplatform/coding_plan/remains")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)
        let requests = await transport.requests()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(requests.contains {
            $0.url?.host == "platform.minimaxi.com" && $0.url?.path.contains("remains") == true
        })
        #expect(requests.contains {
            $0.url?.host == "www.minimaxi.com" && $0.url?.path.contains("remains") == true
        })
    }

    @Test
    func `web usage fetch falls back to www remains host after platform transport failure`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            if url.host == "platform.minimaxi.com", url.path.contains("coding_plan/remains") {
                throw URLError(.timedOut)
            }
            #expect(url.host == "www.minimaxi.com")
            #expect(url.path == "/v1/api/openplatform/coding_plan/remains")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)
        let requests = await transport.requests()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(requests.map { $0.url?.host } == [
            "platform.minimaxi.com",
            "platform.minimaxi.com",
            "www.minimaxi.com",
        ])
    }

    @Test
    func `web usage fetch preserves coding plan json auth failure`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path.contains("coding-plan"))
            return Self.httpResponse(
                url: url,
                body: #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}"#,
                contentType: "application/json")
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "HERTZ-SESSION=expired",
                region: .chinaMainland,
                environment: [:],
                includeBillingHistory: false,
                session: transport)
        }
        let requests = await transport.requests()
        #expect(requests.count == 1)
    }

    @Test
    func `web usage fetch preserves remains json auth failure`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            #expect(url.path.contains("coding_plan/remains"))
            return Self.httpResponse(
                url: url,
                body: #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}"#,
                contentType: "application/json")
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "HERTZ-SESSION=expired",
                region: .chinaMainland,
                environment: [:],
                includeBillingHistory: false,
                session: transport)
        }
        let requests = await transport.requests()
        #expect(requests.map { $0.url?.path } == [
            "/user-center/payment/coding-plan",
            "/v1/api/openplatform/coding_plan/remains",
        ])
    }

    @Test
    func `api token fetch uses official token plan remains endpoint`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "api.minimaxi.com")
            #expect(url.path == "/v1/token_plan/remains")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-cp-test")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            apiToken: "sk-cp-test",
            region: .chinaMainland,
            now: now,
            session: transport)

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
    }

    @Test
    func `api token fetch falls back to legacy coding plan endpoint after official auth failure`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "api.minimaxi.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-standard-test")
            if url.path == "/v1/token_plan/remains" {
                return Self.httpResponse(url: url, body: "{}", statusCode: 401, contentType: "application/json")
            }
            #expect(url.path == "/v1/api/openplatform/coding_plan/remains")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            apiToken: "sk-standard-test",
            region: .chinaMainland,
            now: now,
            session: transport)
        let requests = await transport.requests()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(requests.map { $0.url?.path } == [
            "/v1/token_plan/remains",
            "/v1/api/openplatform/coding_plan/remains",
        ])
    }

    @Test
    func `api token fetch falls back to legacy coding plan endpoint after official parse failure`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "api.minimaxi.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-standard-test")
            if url.path == "/v1/token_plan/remains" {
                return Self.httpResponse(url: url, body: "{}", contentType: "application/json")
            }
            #expect(url.path == "/v1/api/openplatform/coding_plan/remains")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            apiToken: "sk-standard-test",
            region: .chinaMainland,
            now: now,
            session: transport)
        let requests = await transport.requests()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(requests.map { $0.url?.path } == [
            "/v1/token_plan/remains",
            "/v1/api/openplatform/coding_plan/remains",
        ])
    }

    @Test
    func `api token fetch falls back to legacy coding plan endpoint after official transport failure`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "api.minimaxi.com")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-standard-test")
            if url.path == "/v1/token_plan/remains" {
                throw URLError(.timedOut)
            }
            #expect(url.path == "/v1/api/openplatform/coding_plan/remains")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            apiToken: "sk-standard-test",
            region: .chinaMainland,
            now: now,
            session: transport)
        let requests = await transport.requests()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(requests.map { $0.url?.path } == [
            "/v1/token_plan/remains",
            "/v1/api/openplatform/coding_plan/remains",
        ])
    }

    @Test
    func `api token fetch rejects after official and legacy endpoint auth failures`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "api.minimaxi.com")
            #expect([
                "/v1/token_plan/remains",
                "/v1/api/openplatform/coding_plan/remains",
            ].contains(url.path))
            return Self.httpResponse(url: url, body: "{}", statusCode: 401, contentType: "application/json")
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await MiniMaxUsageFetcher.fetchUsage(
                apiToken: "sk-standard-test",
                region: .chinaMainland,
                session: transport)
        }
        let requests = await transport.requests()

        #expect(requests.map { $0.url?.path } == [
            "/v1/token_plan/remains",
            "/v1/api/openplatform/coding_plan/remains",
        ])
    }

    @Test
    func `combo metadata parser extracts token plan subscription label`() throws {
        let metadata = try MiniMaxSubscriptionMetadataFetcher.parse(data: Data(Self.comboMetadataJSON.utf8))
        #expect(metadata.planName == "TokenPlanMax-年度会员")
        #expect(metadata.subscriptionExpiresAt == Date(timeIntervalSince1970: 1_810_656_000))
        #expect(metadata.subscriptionRenewsAt == Date(timeIntervalSince1970: 1_810_569_600))
    }

    @Test
    func `combo metadata parser prefers current subscription over package catalog`() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "data": {
            "current_subscribe": {
              "current_subscribe_title": "TokenPlanUltra-年度会员"
            },
            "packages": [
              { "resource_package_name": "TokenPlanPlus" },
              { "resource_package_name": "TokenPlanMax" },
              { "resource_package_name": "TokenPlanUltra" }
            ]
          }
        }
        """

        let metadata = try MiniMaxSubscriptionMetadataFetcher.parse(data: Data(json.utf8))

        #expect(metadata.planName == "TokenPlanUltra-年度会员")
    }

    @Test
    func `web usage fetch merges combo subscription metadata`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            if url.path.contains("coding_plan/remains") {
                return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
            }
            #expect(url.host == "www.minimaxi.com")
            #expect(url.path == "/v1/api/openplatform/charge/combo/cycle_audio_resource_package")
            #expect(url.query?.contains("biz_line=2") == true)
            #expect(request.value(forHTTPHeaderField: "x-group-id") == "2013894056999916075")
            #expect(request.value(forHTTPHeaderField: "origin") == "https://platform.minimaxi.com")
            return Self.httpResponse(url: url, body: Self.comboMetadataJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "_token=abc; minimax_group_id_v2=2013894056999916075",
            groupID: "2013894056999916075",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)
        let requests = await transport.requests()

        #expect(snapshot.planName == "TokenPlanMax-年度会员")
        #expect(snapshot.subscriptionExpiresAt == Date(timeIntervalSince1970: 1_810_656_000))
        #expect(snapshot.subscriptionRenewsAt == Date(timeIntervalSince1970: 1_810_569_600))
        #expect(snapshot.toUsageSnapshot().subscriptionExpiresAt == Date(timeIntervalSince1970: 1_810_656_000))
        #expect(snapshot.toUsageSnapshot().subscriptionRenewsAt == Date(timeIntervalSince1970: 1_810_569_600))
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(requests.contains { $0.url?.path.contains("cycle_audio_resource_package") == true })
    }

    @Test
    func `combo metadata rejects non https host override before sending credentials`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "<nil>")")
            return Self.httpResponse(
                url: URL(string: "https://unused.example")!,
                body: "{}",
                contentType: "application/json")
        }

        await #expect(throws: ProviderEndpointOverrideError.minimax(MiniMaxSettingsReader.hostKey)) {
            try await MiniMaxSubscriptionMetadataFetcher.fetch(
                cookieHeader: "_token=secret",
                groupID: "2013894056999916075",
                region: .chinaMainland,
                environment: [MiniMaxSettingsReader.hostKey: "http://metadata.test"],
                transport: transport)
        }

        let requests = await transport.requests()
        #expect(requests.isEmpty)
    }

    @Test
    func `combo metadata rejects malformed host override before sending credentials`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            Issue.record("Unexpected request to \(request.url?.absoluteString ?? "<nil>")")
            return Self.httpResponse(
                url: URL(string: "https://unused.example")!,
                body: "{}",
                contentType: "application/json")
        }

        await #expect(throws: ProviderEndpointOverrideError.minimax(MiniMaxSettingsReader.hostKey)) {
            try await MiniMaxSubscriptionMetadataFetcher.fetch(
                cookieHeader: "_token=secret",
                groupID: "2013894056999916075",
                region: .chinaMainland,
                environment: [MiniMaxSettingsReader.hostKey: "bad host"],
                transport: transport)
        }

        let requests = await transport.requests()
        #expect(requests.isEmpty)
    }

    @Test
    func `web usage fetch preserves combo metadata cancellation`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            if url.path.contains("coding_plan/remains") {
                return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
            }
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            try await MiniMaxUsageFetcher.fetchUsage(
                cookieHeader: "_token=abc",
                groupID: "2013894056999916075",
                region: .chinaMainland,
                environment: [:],
                includeBillingHistory: false,
                session: transport,
                now: now)
        }
    }

    @Test
    func `combo metadata failure does not block quota rendering`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            if url.path.contains("coding_plan/remains") {
                return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
            }
            return Self.httpResponse(
                url: url,
                body: #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}"#,
                contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "_token=abc",
            groupID: "2013894056999916075",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)

        #expect(snapshot.planName == nil)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
    }

    private static let comboMetadataJSON = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "data": {
        "current_subscribe": {
          "current_subscribe_title": "TokenPlanMax-年度会员",
          "current_subscribe_end_time": "05/19/2027",
          "renewal_date": "05/18/2027",
          "current_subscribe_end_time_ts": 1810656000000,
          "renewal_trigger_time_ts": 1810569600000
        },
        "packages": [
          {
            "resource_package_name": "TokenPlanMax",
            "display_name": "Token Plan · TokenPlanMax-年度会员"
          }
        ]
      }
    }
    """

    private static let percentBasedRemainsJSON = """
    {
      "model_remains": [
        {
          "start_time": 1780279200000,
          "end_time": 1780297200000,
          "remains_time": 16659830,
          "current_interval_total_count": 0,
          "current_interval_usage_count": 0,
          "model_name": "general",
          "current_weekly_total_count": 0,
          "current_weekly_usage_count": 0,
          "weekly_start_time": 1780243200000,
          "weekly_end_time": 1780848000000,
          "weekly_remains_time": 567459830,
          "current_interval_status": 1,
          "current_interval_remaining_percent": 96,
          "current_weekly_status": 1,
          "current_weekly_remaining_percent": 99
        }
      ],
      "base_resp": { "status_code": 0, "status_msg": "success" }
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
