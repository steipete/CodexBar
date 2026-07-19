import Foundation
import Testing
@testable import CodexBarCore

struct ZaiSettingsReaderTests {
    @Test
    func `api token reads from environment`() {
        let token = ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": "abc123"])
        #expect(token == "abc123")
    }

    @Test
    func `api token strips quotes`() {
        let token = ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }

    @Test
    func `api host reads from environment`() {
        let host = ZaiSettingsReader.apiHost(environment: [ZaiSettingsReader.apiHostKey: " open.bigmodel.cn "])
        #expect(host == "open.bigmodel.cn")
    }

    @Test
    func `quota URL infers scheme`() {
        let url = ZaiSettingsReader
            .quotaURL(environment: [ZaiSettingsReader.quotaURLKey: "open.bigmodel.cn/api/coding"])
        #expect(url?.absoluteString == "https://open.bigmodel.cn/api/coding")
    }

    @Test
    func `endpoint override validation accepts HTTPS and bare hosts`() throws {
        try ZaiSettingsReader.validateEndpointOverrides(environment: [
            ZaiSettingsReader.quotaURLKey: "https://open.bigmodel.cn/api/coding",
        ])
        try ZaiSettingsReader.validateEndpointOverrides(environment: [
            ZaiSettingsReader.apiHostKey: "open.bigmodel.cn",
        ])
    }

    @Test
    func `endpoint override validation rejects insecure URLs`() {
        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.quotaURLKey)) {
            try ZaiSettingsReader.validateEndpointOverrides(environment: [
                ZaiSettingsReader.quotaURLKey: "http://attacker.test/quota",
            ])
        }
        #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            try ZaiSettingsReader.validateEndpointOverrides(environment: [
                ZaiSettingsReader.apiHostKey: "http://attacker.test",
            ])
        }
    }
}

struct ZaiUsageSnapshotTests {
    @Test
    func `maps usage snapshot windows`() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: 20,
            remaining: 80,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let timeLimit = ZaiLimitEntry(
            type: .timeLimit,
            unit: .days,
            number: 30,
            usage: 200,
            currentValue: 40,
            remaining: 160,
            percentage: 50,
            usageDetails: [],
            nextResetTime: nil)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: timeLimit,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "5 hours window")
        #expect(usage.secondary?.usedPercent == 20)
        #expect(usage.secondary?.resetDescription == "30 days window")
        #expect(usage.tertiary == nil)
        #expect(usage.zaiUsage?.tokenLimit?.usage == 100)
        #expect(usage.zaiUsage?.sessionTokenLimit == nil)
    }

    @Test
    func `maps usage snapshot windows with missing fields`() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: nil,
            currentValue: nil,
            remaining: nil,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "5 hours window")
        #expect(usage.zaiUsage?.tokenLimit?.usage == nil)
    }

    @Test
    func `maps usage snapshot windows with missing remaining uses current value`() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: 20,
            remaining: nil,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
    }

    @Test
    func `maps usage snapshot windows with missing current value uses remaining`() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: nil,
            remaining: 80,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
    }

    @Test
    func `maps usage snapshot windows with missing remaining and current value falls back to percentage`() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: nil,
            remaining: nil,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
    }
}

struct ZaiUsageParsingTests {
    @Test
    func `empty body returns parse failed`() {
        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data())
        } throws: { error in
            guard case let ZaiUsageError.parseFailed(message) = error else { return false }
            return message == "Empty response body"
        }
    }

    @Test
    func `parses usage response`() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 100,
                "currentValue": 102,
                "remaining": 0,
                "percentage": 100,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 95 }
                ]
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "usage": 40000000,
                "currentValue": 13628365,
                "remaining": 26371635,
                "percentage": 34,
                "nextResetTime": 1768507567547
              }
            ],
            "planName": "Pro"
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.tokenLimit?.usage == 40_000_000)
        #expect(snapshot.timeLimit?.usageDetails.first?.modelCode == "search-prime")
        #expect(snapshot.tokenLimit?.percentage == 34.0)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.secondary?.windowMinutes == nil)
        #expect(usage.secondary?.resetDescription == "Monthly")
    }

    @Test
    func `zai mcp time limit displays monthly instead of one minute window`() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 100,
                "currentValue": 50,
                "remaining": 50,
                "percentage": 50,
                "usageDetails": []
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 34,
                "nextResetTime": 1768507567547
              }
            ]
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.timeLimit?.windowDescription == "1 minute")
        #expect(usage.secondary?.windowMinutes == nil)
        #expect(usage.secondary?.resetDescription == "Monthly")
    }

    @Test
    func `missing data returns api error`() {
        let json = """
        { "code": 1001, "msg": "Authorization Token Missing", "success": false }
        """

        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        } throws: { error in
            guard case let ZaiUsageError.apiError(message) = error else { return false }
            return message == "Authorization Token Missing"
        }
    }

    @Test
    func `failed response without message reports the API code`() {
        let json = """
        { "code": 1001, "success": false }
        """

        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        } throws: { error in
            guard case let ZaiUsageError.apiError(message) = error else { return false }
            return message == "Z.ai quota API returned code 1001"
        }
    }

    @Test
    func `success without data returns parse failed`() {
        let json = """
        { "code": 200, "msg": "Operation successful", "success": true }
        """

        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        } throws: { error in
            guard case let ZaiUsageError.parseFailed(message) = error else { return false }
            return message == "Missing data"
        }
    }

    @Test
    func `success without limits parses empty usage`() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": { "planName": "Pro" },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.tokenLimit == nil)
        #expect(snapshot.timeLimit == nil)
    }

    @Test
    func `parses new schema with missing token limit fields`() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 100,
                "currentValue": 0,
                "remaining": 100,
                "percentage": 0,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 0 },
                  { "modelCode": "web-reader", "usage": 1 },
                  { "modelCode": "zread", "usage": 0 }
                ]
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 1,
                "nextResetTime": 1770724088678
              }
            ]
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.tokenLimit?.percentage == 1.0)
        #expect(snapshot.tokenLimit?.usage == nil)
        #expect(snapshot.tokenLimit?.currentValue == nil)
        #expect(snapshot.tokenLimit?.remaining == nil)
        #expect(snapshot.tokenLimit?.usedPercent == 1.0)
        #expect(snapshot.tokenLimit?.windowMinutes == 300)
        #expect(snapshot.timeLimit?.usage == 100)
    }

    @Test
    func `parses BigModel CN quota response without message`() throws {
        let json = """
        {
          "code": 200,
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 1000,
                "currentValue": 147,
                "remaining": 853,
                "percentage": 14,
                "nextResetTime": 1784706344993,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 84 },
                  { "modelCode": "web-reader", "usage": 41 },
                  { "modelCode": "zread", "usage": 8 }
                ]
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 8,
                "nextResetTime": 1783049703178
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "percentage": 7,
                "nextResetTime": 1783496744998
              }
            ],
            "level": "pro"
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 7)
        #expect(usage.secondary?.usedPercent == 14.7)
        #expect(usage.tertiary?.usedPercent == 8)
    }
}

struct ZaiBigModelTeamScopeTests {
    @Test
    func `team scope appends type 2 and sends BigModel project headers`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let json = """
            {
              "code": 200,
              "msg": "操作成功",
              "data": {
                "level": "pro",
                "limits": [
                  {
                    "type": "TIME_LIMIT",
                    "unit": 5,
                    "number": 1,
                    "usage": 1000,
                    "currentValue": 224,
                    "remaining": 776,
                    "percentage": 22,
                    "nextResetTime": 1777575229998,
                    "usageDetails": []
                  },
                  {
                    "type": "TOKENS_LIMIT",
                    "unit": 3,
                    "number": 5,
                    "percentage": 25,
                    "nextResetTime": 1775020168897
                  },
                  {
                    "type": "TOKENS_LIMIT",
                    "unit": 6,
                    "number": 1,
                    "percentage": 9,
                    "nextResetTime": 1775588029998
                  }
                ]
              },
              "success": true
            }
            """
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!)
        }

        let snapshot = try await ZaiUsageFetcher.fetchUsage(
            apiKey: "zai-test-token",
            region: .bigmodelCN,
            usageScope: .team,
            teamContext: ZaiBigModelTeamContext(
                organizationID: "org-test",
                projectID: "proj-test"),
            environment: [:],
            transport: transport)

        let requests = await transport.requests()
        let request = try #require(requests.first)

        #expect(request.url?.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit?type=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer zai-test-token")
        #expect(request.value(forHTTPHeaderField: "Bigmodel-Organization") == "org-test")
        #expect(request.value(forHTTPHeaderField: "Bigmodel-Project") == "proj-test")
        #expect(snapshot.tokenLimit?.unit == .weeks)
        #expect(snapshot.sessionTokenLimit?.unit == .hours)
        #expect(snapshot.timeLimit?.usage == 1000)
    }

    @Test
    func `personal scope keeps existing quota URL and omits team headers`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let json = """
            {
              "code": 200,
              "msg": "Operation successful",
              "data": {
                "limits": [
                  {
                    "type": "TOKENS_LIMIT",
                    "unit": 3,
                    "number": 5,
                    "percentage": 34,
                    "nextResetTime": 1768507567547
                  }
                ]
              },
              "success": true
            }
            """
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!)
        }

        _ = try await ZaiUsageFetcher.fetchUsage(
            apiKey: "zai-test-token",
            region: .bigmodelCN,
            usageScope: .personal,
            teamContext: ZaiBigModelTeamContext(
                organizationID: "org-test",
                projectID: "proj-test"),
            environment: [:],
            transport: transport)

        let requests = await transport.requests()
        let request = try #require(requests.first)

        #expect(request.url?.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        #expect(request.value(forHTTPHeaderField: "Bigmodel-Organization") == nil)
        #expect(request.value(forHTTPHeaderField: "Bigmodel-Project") == nil)
    }

    @Test
    func `team scope requires complete BigModel context`() async {
        let transport = ProviderHTTPTransportStub { request in
            (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!)
        }

        await self.expectMissingTeamContext {
            _ = try await ZaiUsageFetcher.fetchUsage(
                apiKey: "zai-test-token",
                region: .bigmodelCN,
                usageScope: .team,
                teamContext: nil,
                environment: [:],
                transport: transport)
        }

        let requests = await transport.requests()
        #expect(requests.isEmpty)

        await self.expectMissingTeamContext {
            _ = try await ZaiUsageFetcher.fetchUsage(
                apiKey: "zai-test-token",
                region: .bigmodelCN,
                usageScope: .team,
                teamContext: nil,
                environment: [ZaiSettingsReader.bigModelOrganizationKey: "org-only"],
                transport: transport)
        }

        await self.expectMissingTeamContext {
            _ = try await ZaiUsageFetcher.fetchUsage(
                apiKey: "zai-test-token",
                region: .bigmodelCN,
                usageScope: .team,
                teamContext: nil,
                environment: [ZaiSettingsReader.bigModelProjectKey: "proj-only"],
                transport: transport)
        }
    }

    @Test
    func `team model usage appends type 3 and sends BigModel project headers`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let json = """
            {
              "code": 200,
              "msg": "success",
              "success": true,
              "data": {
                "x_time": ["2026-06-21 08:00"],
                "modelDataList": [
                  { "modelName": "glm-4.6", "tokensUsage": [100] }
                ]
              }
            }
            """
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!)
        }

        let usage = try await ZaiUsageFetcher.fetchModelUsage(
            apiKey: "zai-test-token",
            region: .bigmodelCN,
            usageScope: .team,
            teamContext: ZaiBigModelTeamContext(
                organizationID: "org-test",
                projectID: "proj-test"),
            environment: [:],
            transport: transport)

        let requests = await transport.requests()
        let request = try #require(requests.first)
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))

        #expect(components.path == "/api/monitor/usage/model-usage")
        #expect(components.queryItems?.first { $0.name == "type" }?.value == "3")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer zai-test-token")
        #expect(request.value(forHTTPHeaderField: "Bigmodel-Organization") == "org-test")
        #expect(request.value(forHTTPHeaderField: "Bigmodel-Project") == "proj-test")
        #expect(usage.modelNames == ["glm-4.6"])
    }

    @Test
    func `team quota rejects insecure override before sending credentials`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            Issue.record("Unexpected z.ai team quota request to \(request.url?.absoluteString ?? "<nil>")")
            throw URLError(.badURL)
        }

        await #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.quotaURLKey)) {
            try await ZaiUsageFetcher.fetchUsage(
                apiKey: "zai-test-token",
                region: .bigmodelCN,
                usageScope: .team,
                teamContext: ZaiBigModelTeamContext(
                    organizationID: "org-test",
                    projectID: "proj-test"),
                environment: [ZaiSettingsReader.quotaURLKey: "http://attacker.test/quota"],
                transport: transport)
        }

        let requests = await transport.requests()
        #expect(requests.isEmpty)
    }

    @Test
    func `team model usage rejects insecure API host before sending credentials`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            Issue.record("Unexpected z.ai team model usage request to \(request.url?.absoluteString ?? "<nil>")")
            throw URLError(.badURL)
        }

        await #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            try await ZaiUsageFetcher.fetchModelUsage(
                apiKey: "zai-test-token",
                region: .bigmodelCN,
                usageScope: .team,
                teamContext: ZaiBigModelTeamContext(
                    organizationID: "org-test",
                    projectID: "proj-test"),
                environment: [ZaiSettingsReader.apiHostKey: "http://attacker.test"],
                transport: transport)
        }

        let requests = await transport.requests()
        #expect(requests.isEmpty)
    }

    private func expectMissingTeamContext(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected z.ai missing team context error.")
        } catch ZaiUsageError.missingTeamContext {
            // Expected.
        } catch {
            Issue.record("Expected z.ai missing team context error, got \(error).")
        }
    }

    @Test
    func `team context can be resolved from environment`() {
        let env = [
            ZaiSettingsReader.bigModelOrganizationKey: " org-env ",
            ZaiSettingsReader.bigModelProjectKey: " proj-env ",
        ]

        #expect(ZaiBigModelTeamContext(environment: env)?.organizationID == "org-env")
        #expect(ZaiBigModelTeamContext(environment: env)?.projectID == "proj-env")
    }
}

struct ZaiHourlyUsageTests {
    @Test
    func `model usage parser decodes hourly model payload`() throws {
        let json = """
        {
          "code": 200,
          "msg": "success",
          "success": true,
          "data": {
            "x_time": ["2026-05-14 08:00", "2026-05-14 09:00"],
            "modelDataList": [
              { "modelName": "glm-4.6", "tokensUsage": [100, null] },
              { "modelName": "glm-4.5", "tokensUsage": [50, 25] }
            ]
          }
        }
        """

        let usage = try ZaiUsageFetcher.parseModelUsage(from: Data(json.utf8))

        #expect(usage.xTime == ["2026-05-14 08:00", "2026-05-14 09:00"])
        #expect(usage.modelNames == ["glm-4.6", "glm-4.5"])
        #expect(usage.modelDataList[0].tokensUsage == [100, nil])
        #expect(usage.modelDataList[1].tokensUsage == [50, 25])
    }

    @Test
    func `today hourly bars filter earlier days and skip empty hours`() {
        let reference = Self.localDate(year: 2026, month: 5, day: 14, hour: 12)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: reference) ?? reference
        let modelData = ZaiModelUsageData(
            xTime: [
                Self.hourString(yesterday),
                "2026-05-14 08:00",
                "2026-05-14 09:00",
            ],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [999, 100, 0]),
                ZaiModelDataItem(modelName: "glm-4.5", tokensUsage: [0, 50, nil]),
            ])

        let bars = ZaiHourlyBars.from(modelData: modelData, range: .today(referenceDate: reference), now: reference)

        #expect(bars.map(\.label) == ["08"])
        #expect(bars.first?.totalTokens == 150)
        #expect(bars.first?.segments.count == 2)
    }

    @Test
    func `last 24 hour bars filter data outside trailing window`() {
        let reference = Self.localDate(year: 2026, month: 5, day: 14, hour: 12)
        let old = Calendar.current.date(byAdding: .hour, value: -25, to: reference) ?? reference
        let inWindow = Calendar.current.date(byAdding: .hour, value: -23, to: reference) ?? reference
        let modelData = ZaiModelUsageData(
            xTime: [
                Self.hourString(old),
                Self.hourString(inWindow),
                Self.hourString(reference),
            ],
            modelDataList: [
                ZaiModelDataItem(modelName: "glm-4.6", tokensUsage: [10, 20, 30]),
            ])

        let bars = ZaiHourlyBars.from(modelData: modelData, range: .last24h, now: reference)

        #expect(bars.map(\.label) == [Self.hourLabel(inWindow), Self.hourLabel(reference)])
        #expect(bars.map(\.totalTokens) == [20, 30])
    }

    private static func localDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }

    private static func hourString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

struct ZaiThreeLimitTests {
    @Test
    func `parses three limit entries into session weekly and mcp slots`() throws {
        let json = """
        {
          "code": 200,
          "msg": "操作成功",
          "data": {
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 25,
                "nextResetTime": 1775020168897
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "percentage": 9,
                "nextResetTime": 1775588029998
              },
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 1000,
                "currentValue": 224,
                "remaining": 776,
                "percentage": 22,
                "nextResetTime": 1777575229998,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 210 },
                  { "modelCode": "web-reader", "usage": 14 }
                ]
              }
            ],
            "level": "pro"
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        // Weekly token limit (unit:6=weeks, longer window) → tokenLimit (primary)
        #expect(snapshot.tokenLimit?.unit == .weeks)
        #expect(snapshot.tokenLimit?.number == 1)
        #expect(snapshot.tokenLimit?.percentage == 9.0)
        #expect(snapshot.tokenLimit?.windowMinutes == 10080)

        // 5-hour token limit (unit:3=hours, number:5 → 300 min) → sessionTokenLimit (tertiary)
        #expect(snapshot.sessionTokenLimit?.unit == .hours)
        #expect(snapshot.sessionTokenLimit?.number == 5)
        #expect(snapshot.sessionTokenLimit?.percentage == 25.0)
        #expect(snapshot.sessionTokenLimit?.windowMinutes == 300)

        // MCP time limit → timeLimit (secondary)
        #expect(snapshot.timeLimit?.usage == 1000)
        #expect(snapshot.timeLimit?.usageDetails.first?.modelCode == "search-prime")

        // UsageSnapshot slot mapping
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 9.0)
        #expect(usage.primary?.windowMinutes == 10080)
        #expect(usage.secondary != nil) // MCP
        #expect(usage.tertiary?.usedPercent == 25.0)
        #expect(usage.tertiary?.windowMinutes == 300)
    }

    @Test
    func `unit 6 maps to weeks with correct window minutes`() {
        let entry = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .weeks,
            number: 1,
            usage: nil,
            currentValue: nil,
            remaining: nil,
            percentage: 9,
            usageDetails: [],
            nextResetTime: nil)
        #expect(entry.windowMinutes == 10080)
        #expect(entry.windowDescription == "1 week")
        #expect(entry.windowLabel == "1 week window")
    }

    @Test
    func `two limit entries remain backward compatible`() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 100,
                "currentValue": 50,
                "remaining": 50,
                "percentage": 50,
                "usageDetails": []
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 34,
                "nextResetTime": 1768507567547
              }
            ]
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.tokenLimit != nil)
        #expect(snapshot.sessionTokenLimit == nil)
        #expect(snapshot.timeLimit != nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary != nil)
        #expect(usage.secondary != nil)
        #expect(usage.tertiary == nil)
    }
}

struct ZaiAPIRegionTests {
    @Test
    func `dashboard URLs follow selected region`() {
        #expect(
            ZaiAPIRegion.global.dashboardURL.absoluteString ==
                "https://z.ai/manage-apikey/coding-plan/personal/my-plan")
        #expect(
            ZaiAPIRegion.bigmodelCN.dashboardURL.absoluteString ==
                "https://bigmodel.cn/coding-plan/personal/usage")
        #expect(
            ZaiProviderDescriptor.descriptor.metadata.dashboardURL ==
                ZaiAPIRegion.global.dashboardURL.absoluteString)
    }

    @Test
    func `defaults to global endpoint`() {
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: [:])
        #expect(url.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
    }

    @Test
    func `uses big model region when selected`() {
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .bigmodelCN, environment: [:])
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    }

    @Test
    func `quota url environment override wins`() {
        let env = [ZaiSettingsReader.quotaURLKey: "https://open.bigmodel.cn/api/coding/paas/v4"]
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: env)
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/coding/paas/v4")
    }

    @Test
    func `api host environment appends quota path`() {
        let env = [ZaiSettingsReader.apiHostKey: "open.bigmodel.cn"]
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: env)
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    }

    @Test
    func `dashboard follows known endpoint overrides`() {
        let china = ZaiUsageFetcher.resolveDashboardURL(
            region: .global,
            environment: [ZaiSettingsReader.apiHostKey: "open.bigmodel.cn"])
        #expect(china == ZaiAPIRegion.bigmodelCN.dashboardURL)

        let global = ZaiUsageFetcher.resolveDashboardURL(
            region: .bigmodelCN,
            environment: [ZaiSettingsReader.apiHostKey: "api.z.ai"])
        #expect(global == ZaiAPIRegion.global.dashboardURL)
    }

    @Test
    func `dashboard keeps selected region for custom endpoint override`() {
        let dashboard = ZaiUsageFetcher.resolveDashboardURL(
            region: .bigmodelCN,
            environment: [ZaiSettingsReader.apiHostKey: "zai.internal.example"])

        #expect(dashboard == ZaiAPIRegion.bigmodelCN.dashboardURL)
    }
}
