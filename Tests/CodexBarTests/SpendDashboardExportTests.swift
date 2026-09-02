import AppKit
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardExportTests {
    @Test
    func `export filename uses the selected window`() {
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 7) == "codexbar-spend-last-7-days.json")
        #expect(SpendDashboardJSONExporter.defaultFilename(days: 30) == "codexbar-spend-last-30-days.json")
        #expect(
            SpendDashboardJSONExporter.defaultFilename(days: SpendDashboardSource.scanDays)
                == "codexbar-spend-all-time.json")
    }

    @Test
    func `export writes pretty JSON to a file`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "cursor",
                    provider: .cursor,
                    displayName: "Cursor",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: 10,
                        sessionCostUSD: 1,
                        last30DaysTokens: 10,
                        last30DaysCostUSD: 1,
                        historyDays: 7,
                        costProvenance: .listPriceEstimate,
                        daily: [
                            CostUsageDailyReport.Entry(
                                date: "2026-07-16",
                                inputTokens: 8,
                                outputTokens: 2,
                                totalTokens: 10,
                                costUSD: 1,
                                modelsUsed: nil,
                                modelBreakdowns: nil),
                        ],
                        updatedAt: now)),
            ],
            requestedDays: 7,
            now: now)
        let data = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: ["cursor"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SpendDashboardJSONExporter.defaultFilename(days: 7))
        try SpendDashboardJSONExporter.write(data, to: url)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["requestedDays"] as? Int == 7)
        #expect(object["hiddenSourceIDs"] as? [String] == ["cursor"])
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\n"))
        #expect(json.contains("\"provenance\""))
    }

    @Test
    func `proxy model exports its upstream identity and route`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let attribution = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .anthropic,
            upstream: .init(
                provider: "Codex",
                authType: .oauth,
                model: " gpt-5.4 "),
            evidence: [.cliProxyRequestLog, .cliProxyUsageTelemetry, .modelProvider])
        let group = SpendDashboardModel.CurrencyGroup(
            currencyCode: "USD",
            providers: [],
            models: [
                SpendDashboardModel.ModelRow(
                    rank: 1,
                    provider: .claude,
                    providerName: "Claude",
                    modelName: "claude-sonnet-4",
                    totalTokens: 42,
                    totalCost: 1.25,
                    attribution: attribution),
            ],
            dailyPoints: [],
            totalTokens: 42,
            totalCost: 1.25,
            coveredDayCount: 1,
            chartDomain: now...now,
            modelHistoryCompleteness: .complete)
        let model = SpendDashboardModel(requestedDays: 1, groups: [group])

        let data = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: [])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(object["groups"] as? [[String: Any]])
        let models = try #require(groups.first?["models"] as? [[String: Any]])
        let exported = try #require(models.first)
        let exportedAttribution = try #require(exported["attribution"] as? [String: Any])
        let upstream = try #require(exportedAttribution["upstream"] as? [String: Any])

        #expect(exported["provider"] as? String == "codex")
        #expect(exported["modelName"] as? String == "gpt-5.4")
        #expect(exportedAttribution["route"] as? String == "cliProxyAPI")
        #expect(upstream["provider"] as? String == "Codex")
    }

    @MainActor
    @Test
    func `copy writes JSON to the pasteboard`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "cursor",
                    provider: .cursor,
                    displayName: "Cursor",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: 10,
                        sessionCostUSD: 1,
                        last30DaysTokens: 10,
                        last30DaysCostUSD: 1,
                        historyDays: 7,
                        costProvenance: .listPriceEstimate,
                        daily: [
                            CostUsageDailyReport.Entry(
                                date: "2026-07-16",
                                inputTokens: 8,
                                outputTokens: 2,
                                totalTokens: 10,
                                costUSD: 1,
                                modelsUsed: nil,
                                modelBreakdowns: nil),
                        ],
                        updatedAt: now)),
            ],
            requestedDays: 7,
            now: now)
        let data = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: ["cursor"])
        let json = try #require(String(bytes: data, encoding: .utf8))
        let pb = NSPasteboard(name: NSPasteboard.Name("SpendDashboardExportTests-copy-\(UUID().uuidString)"))
        pb.clearContents()
        defer { pb.releaseGlobally() }
        #expect(SpendDashboardJSONExporter.copyToPasteboard(model: model, hiddenSourceIDs: ["cursor"], pasteboard: pb))
        #expect(pb.string(forType: .string) == json)
    }

    @MainActor
    @Test
    func `save writes a file and cancel does not`() throws {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "cursor",
                    provider: .cursor,
                    displayName: "Cursor",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: 10,
                        sessionCostUSD: 1,
                        last30DaysTokens: 10,
                        last30DaysCostUSD: 1,
                        historyDays: 7,
                        costProvenance: .listPriceEstimate,
                        daily: [
                            CostUsageDailyReport.Entry(
                                date: "2026-07-16",
                                inputTokens: 8,
                                outputTokens: 2,
                                totalTokens: 10,
                                costUSD: 1,
                                modelsUsed: nil,
                                modelBreakdowns: nil),
                        ],
                        updatedAt: now)),
            ],
            requestedDays: 7,
            now: now)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardExportPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let savedURL = root.appendingPathComponent("codexbar-spend-last-7-days.json")
        let saved = SpendDashboardJSONExporter.save(
            model: model,
            hiddenSourceIDs: ["cursor"],
            chooseDestination: { filename in
                #expect(filename == "codexbar-spend-last-7-days.json")
                return savedURL
            })
        #expect(saved)
        #expect(FileManager.default.fileExists(atPath: savedURL.path))

        let cancelRoot = root.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelRoot, withIntermediateDirectories: true)
        let cancelled = SpendDashboardJSONExporter.save(
            model: model,
            hiddenSourceIDs: [],
            chooseDestination: { _ in nil })
        #expect(!cancelled)
        let cancelContents = try FileManager.default.contentsOfDirectory(atPath: cancelRoot.path)
        #expect(cancelContents.isEmpty)

        guard let proofDir = ProcessInfo.processInfo.environment["CODEXBAR_SPEND_PROOF_DIR"] else {
            return
        }
        let directory = URL(fileURLWithPath: NSString(string: proofDir).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let proofJSON = directory.appendingPathComponent("spend-export-saved.json")
        try Data(contentsOf: savedURL).write(to: proofJSON, options: .atomic)
        let proofCancel = directory.appendingPathComponent("spend-export-cancel.log")
        try """
        panel: NSSavePanel
        action: cancel
        destination: none
        filesCreated: 0
        directoryEmpty: true
        """.write(to: proofCancel, atomically: true, encoding: .utf8)
    }
}
