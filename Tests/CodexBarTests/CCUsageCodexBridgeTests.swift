import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CCUsageCodexBridgeTests {
    @Test
    func `parses only Codex agent rows and preserves token categories`() throws {
        let json = #"""
        {
          "daily": [
            {
              "period": "2026-08-09",
              "agents": [
                {
                  "agent": "codex",
                  "inputTokens": 120,
                  "outputTokens": 30,
                  "cacheReadTokens": 800,
                  "cacheCreationTokens": 5,
                  "totalTokens": 955,
                  "totalCost": 999.99,
                  "modelsUsed": ["gpt-5.6-sol"],
                  "modelBreakdowns": [
                    {
                      "modelName": "gpt-5.6-sol",
                      "inputTokens": 120,
                      "outputTokens": 30,
                      "cacheReadTokens": 800,
                      "cacheCreationTokens": 5,
                      "cost": 999.99
                    }
                  ]
                },
                {
                  "agent": "claude",
                  "inputTokens": 999,
                  "outputTokens": 999,
                  "totalTokens": 1998,
                  "totalCost": 9.99
                }
              ]
            }
          ],
          "totals": { "totalTokens": 2953, "totalCost": 11.24 }
        }
        """#

        let report = try CCUsageCodexBridge.parseReport(Data(json.utf8))

        #expect(report.data.count == 1)
        #expect(report.data[0].date == "2026-08-09")
        #expect(report.data[0].inputTokens == 120)
        #expect(report.data[0].outputTokens == 30)
        #expect(report.data[0].cacheReadTokens == 800)
        #expect(report.data[0].cacheCreationTokens == 5)
        #expect(report.data[0].totalTokens == 955)
        #expect(abs((report.data[0].costUSD ?? 0) - 0.00193125) < 0.0000000001)
        #expect(report.data[0].modelBreakdowns?.first?.totalTokens == 955)
        #expect(abs((report.data[0].modelBreakdowns?.first?.costUSD ?? 0) - 0.00193125) < 0.0000000001)
        #expect(report.summary?.totalTokens == 955)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - 0.00193125) < 0.0000000001)
    }

    @Test
    func `reprices Luna and Terra from token categories instead of helper costs`() throws {
        let json = #"""
        {
          "daily": [
            {
              "period": "2026-08-10",
              "agents": [
                {
                  "agent": "codex",
                  "inputTokens": 2000000,
                  "outputTokens": 200000,
                  "cacheReadTokens": 20000000,
                  "cacheCreationTokens": 0,
                  "totalTokens": 22200000,
                  "totalCost": 260.0,
                  "modelsUsed": ["gpt-5.6-luna", "gpt-5.6-terra"],
                  "modelBreakdowns": [
                    {
                      "modelName": "gpt-5.6-luna",
                      "inputTokens": 1000000,
                      "outputTokens": 100000,
                      "cacheReadTokens": 10000000,
                      "cacheCreationTokens": 0,
                      "totalTokens": 11100000,
                      "cost": 52.0
                    },
                    {
                      "modelName": "gpt-5.6-terra",
                      "inputTokens": 1000000,
                      "outputTokens": 100000,
                      "cacheReadTokens": 10000000,
                      "cacheCreationTokens": 0,
                      "totalTokens": 11100000,
                      "cost": 208.0
                    }
                  ]
                }
              ]
            }
          ]
        }
        """#

        let report = try CCUsageCodexBridge.parseReport(Data(json.utf8))
        let breakdowns = try #require(report.data[0].modelBreakdowns)
        let luna = try #require(breakdowns.first { $0.modelName == "gpt-5.6-luna" })
        let terra = try #require(breakdowns.first { $0.modelName == "gpt-5.6-terra" })

        #expect(abs((luna.costUSD ?? 0) - 0.52) < 0.0000000001)
        #expect(abs((terra.costUSD ?? 0) - 5.2) < 0.0000000001)
        #expect(abs((report.data[0].costUSD ?? 0) - 5.72) < 0.0000000001)
        #expect(abs((report.summary?.totalCostUSD ?? 0) - 5.72) < 0.0000000001)
    }

    @Test
    func `builds scoped offline arguments and environment`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let since = Date(timeIntervalSince1970: 1_786_205_600)
        let until = Date(timeIntervalSince1970: 1_786_292_000)

        let arguments = CCUsageCodexBridge.arguments(since: since, until: until, calendar: calendar)
        let environment = CCUsageCodexBridge.subprocessEnvironment(
            environment: ["TEST_SCOPE": "yes"],
            codexHomePath: "/tmp/codex-profile")

        #expect(arguments == [
            "daily", "--json", "--by-agent", "--offline", "--no-color",
            "--timezone", "Asia/Shanghai", "--since", "2026-08-09", "--until", "2026-08-10",
        ])
        #expect(environment["TEST_SCOPE"] == "yes")
        #expect(environment["CODEX_HOME"] == "/tmp/codex-profile")
    }

    @Test
    func `successful fallback uses the selected Codex home`() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        let helper = try fixture.writeHelper("""
        case "$CODEX_HOME" in */codex-home) ;; *) exit 7 ;; esac
        printf '%s\\n' '{"daily":[{"period":"2026-08-09","agents":[{"agent":"codex","inputTokens":120,"outputTokens":30,"cacheReadTokens":800,"cacheCreationTokens":5,"totalTokens":955,"totalCost":1.25,"modelsUsed":["gpt-5.6-sol"],"modelBreakdowns":[{"modelName":"gpt-5.6-sol","inputTokens":120,"outputTokens":30,"cacheReadTokens":800,"cacheCreationTokens":5,"totalTokens":955,"cost":1.25}]}]}]}'
        """)

        let report = await CCUsageCodexBridge.loadFallbackReportIfNeeded(
            nativeReport: Self.report(tokens: 10),
            historyCoverageIsEstablished: false,
            since: fixture.since,
            until: fixture.until,
            calendar: fixture.calendar,
            environment: ["CODEXBAR_CCUSAGE_PATH": helper.path],
            codexHomePath: fixture.codexHome.path)

        #expect(report?.summary?.totalTokens == 955)
        #expect(abs((report?.summary?.totalCostUSD ?? 0) - 0.00193125) < 0.0000000001)
    }

    @Test
    func `does not invoke helper when native coverage is established`() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        let marker = fixture.root.appendingPathComponent("invoked")
        let helper = try fixture.writeHelper("""
        touch "$CCUSAGE_TEST_MARKER"
        exit 1
        """)

        let report = await CCUsageCodexBridge.loadFallbackReportIfNeeded(
            nativeReport: Self.report(tokens: 10),
            historyCoverageIsEstablished: true,
            since: fixture.since,
            until: fixture.until,
            calendar: fixture.calendar,
            environment: [
                "CODEXBAR_CCUSAGE_PATH": helper.path,
                "CCUSAGE_TEST_MARKER": marker.path,
            ],
            codexHomePath: fixture.codexHome.path)

        #expect(report == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func `failed helper executions retain native result`() async throws {
        let cases = [
            ("exit 9", "subprocess failure"),
            ("printf '%s\\n' 'not json'", "invalid json"),
            ("sleep 1", "timeout"),
        ]

        for (body, _) in cases {
            let fixture = try Self.fixture()
            let helper = try fixture.writeHelper(body)
            let report = await CCUsageCodexBridge.loadFallbackReportIfNeeded(
                nativeReport: Self.report(tokens: 10),
                historyCoverageIsEstablished: false,
                since: fixture.since,
                until: fixture.until,
                calendar: fixture.calendar,
                environment: ["CODEXBAR_CCUSAGE_PATH": helper.path],
                codexHomePath: fixture.codexHome.path,
                timeout: body == "sleep 1" ? 0.05 : 30)
            #expect(report == nil)
            fixture.cleanup()
        }
    }

    @Test
    func `missing helper and lower token fallback are rejected`() async throws {
        let fixture = try Self.fixture()
        defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("missing-ccusage")
        let missingReport = await CCUsageCodexBridge.loadFallbackReportIfNeeded(
            nativeReport: Self.report(tokens: 10),
            historyCoverageIsEstablished: false,
            since: fixture.since,
            until: fixture.until,
            calendar: fixture.calendar,
            environment: ["CODEXBAR_CCUSAGE_PATH": missing.path],
            codexHomePath: fixture.codexHome.path)
        #expect(missingReport == nil)

        let lowerHelper = try fixture
            .writeHelper(
                "printf '%s\\n' '{\"daily\":[{\"period\":\"2026-08-09\",\"agents\":[{\"agent\":\"codex\",\"totalTokens\":1,\"totalCost\":0.01}]}]}'")
        let lowerReport = await CCUsageCodexBridge.loadFallbackReportIfNeeded(
            nativeReport: Self.report(tokens: 10),
            historyCoverageIsEstablished: false,
            since: fixture.since,
            until: fixture.until,
            calendar: fixture.calendar,
            environment: ["CODEXBAR_CCUSAGE_PATH": lowerHelper.path],
            codexHomePath: fixture.codexHome.path)
        #expect(lowerReport == nil)
    }

    private static func report(tokens: Int) -> CostUsageDailyReport {
        CostUsageDailyReport(
            data: [CostUsageDailyReport.Entry(
                date: "2026-08-09",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: tokens,
                costUSD: 0.1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            summary: CostUsageDailyReport.Summary(
                totalInputTokens: nil,
                totalOutputTokens: nil,
                totalTokens: tokens,
                totalCostUSD: 0.1))
    }

    private struct Fixture {
        let root: URL
        let codexHome: URL
        let since: Date
        let until: Date
        let calendar: Calendar

        func writeHelper(_ body: String) throws -> URL {
            let url = self.root.appendingPathComponent("ccusage-\(UUID().uuidString)")
            try ("#!/bin/sh\nset -eu\n\(body)\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }

    private static func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-ccusage-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return Fixture(
            root: root,
            codexHome: codexHome,
            since: Date(timeIntervalSince1970: 1_786_205_600),
            until: Date(timeIntervalSince1970: 1_786_292_000),
            calendar: calendar)
    }
}
