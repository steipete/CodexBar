import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
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

    @MainActor
    @Test
    func `copy writes JSON to the pasteboard`() throws {
        let model = Self.makeModel()
        let data = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: ["cursor"])
        let json = try #require(String(bytes: data, encoding: .utf8))
        let pb = NSPasteboard(name: NSPasteboard.Name("SpendDashboardExportTests-copy-\(UUID().uuidString)"))
        pb.clearContents()
        defer { pb.releaseGlobally() }
        #expect(SpendDashboardJSONExporter.copyToPasteboard(model: model, hiddenSourceIDs: ["cursor"], pasteboard: pb))
        #expect(pb.string(forType: .string) == json)
    }

    @Test
    func `export document reads and writes JSON only`() {
        #expect(SpendDashboardJSONDocument.readableContentTypes == [.json])
        #expect(SpendDashboardJSONDocument.writableContentTypes == [.json])
    }

    @Test
    func `export document matches the copied JSON bytes`() throws {
        let model = Self.makeModel()
        let document = try SpendDashboardJSONDocument(model: model, hiddenSourceIDs: ["cursor"])
        let encoded = try SpendDashboardJSONExporter.encodedData(model: model, hiddenSourceIDs: ["cursor"])
        #expect(document.data == encoded)
    }

    @Test
    func `export document writes pretty JSON to a file`() throws {
        let document = try SpendDashboardJSONDocument(model: Self.makeModel(), hiddenSourceIDs: ["cursor"])
        let wrapper = document.fileWrapper()
        #expect(wrapper.isRegularFile)
        #expect(wrapper.regularFileContents == document.data)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(SpendDashboardJSONExporter.defaultFilename(days: 7))
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)

        let written = try Data(contentsOf: url)
        #expect(written == document.data)
        let object = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["requestedDays"] as? Int == 7)
        #expect(object["hiddenSourceIDs"] as? [String] == ["cursor"])
        let json = try #require(String(bytes: written, encoding: .utf8))
        #expect(json.contains("\n"))
        #expect(json.contains("\"provenance\""))
    }

    @Test
    func `export document round trips through a file wrapper`() throws {
        let document = try SpendDashboardJSONDocument(model: Self.makeModel(), hiddenSourceIDs: [])
        let reopened = try SpendDashboardJSONDocument(fileWrapper: document.fileWrapper())
        #expect(reopened.data == document.data)
    }

    @Test
    func `export document rejects a folder`() {
        let folder = FileWrapper(directoryWithFileWrappers: [:])
        #expect(throws: CocoaError.self) {
            try SpendDashboardJSONDocument(fileWrapper: folder)
        }
    }

    @Test
    func `export result only reports real failures`() {
        let saved = URL(fileURLWithPath: "/tmp/codexbar-spend-last-7-days.json")
        #expect(!SpendDashboardJSONDocument.exportFailed(.success(saved)))
        #expect(!SpendDashboardJSONDocument.exportFailed(.failure(CocoaError(.userCancelled))))
        #expect(SpendDashboardJSONDocument.exportFailed(.failure(CocoaError(.fileWriteNoPermission))))
        #expect(SpendDashboardJSONDocument.exportFailed(.failure(URLError(.cannotCreateFile))))
    }

    private static func makeModel() -> SpendDashboardModel {
        let now = Date(timeIntervalSince1970: 1_784_179_200)
        return SpendDashboardModel.build(
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
    }
}
