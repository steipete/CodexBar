import Foundation
import Testing
@testable import CodexBarCore

struct ProviderDetailSectionTests {
    @Test
    func `construction trims strings and preserves valid detail data`() throws {
        let point = try ProviderDetailSection.Chart.Point(label: " Monday ", value: 12.5)
        let chart = try ProviderDetailSection.Chart(
            kind: .bars,
            title: " Daily usage ",
            unit: " USD ",
            points: [point])
        let row = try ProviderDetailSection.Row(
            label: " Total ",
            value: " $12.50 ",
            secondaryValue: " 120 requests ")
        let section = try ProviderDetailSection(title: " Billing ", rows: [row], chart: chart)

        #expect(section.title == "Billing")
        #expect(try section.rows == [ProviderDetailSection.Row(
            label: "Total",
            value: "$12.50",
            secondaryValue: "120 requests")])
        #expect(section.chart?.title == "Daily usage")
        #expect(section.chart?.unit == "USD")
        #expect(try section.chart?.points == [ProviderDetailSection.Chart.Point(label: "Monday", value: 12.5)])
    }

    @Test
    func `construction rejects invalid bounds and nonfinite points`() throws {
        let row = try ProviderDetailSection.Row(label: "Label", value: "Value")
        let point = try ProviderDetailSection.Chart.Point(label: "Point", value: 1)

        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection.Row(label: String(repeating: "x", count: 121), value: "Value")
        }
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection.Chart.Point(label: "Point", value: .infinity)
        }
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection(rows: Array(repeating: row, count: 25))
        }
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection.Chart(kind: .line, points: Array(repeating: point, count: 121))
        }
    }

    @Test
    func `decoding rejects too many sections`() throws {
        let section = #"{"rows":[]}"#
        let details = Array(repeating: section, count: 9).joined(separator: ",")
        let json = """
        {
          "primary": null,
          "secondary": null,
          "tertiary": null,
          "details": [\(details)],
          "updatedAt": "2026-08-02T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
        }
    }

    @Test
    func `row progress divides used by total without clamping`() throws {
        let progress = try ProviderDetailSection.Row.Progress(used: 31, total: 3000)
        #expect(abs(progress.usedPercent - 1.0333333) < 0.0001)
        #expect(try ProviderDetailSection.Row.Progress(used: 150, total: 100).usedPercent == 150)
    }

    @Test
    func `row progress rejects non positive totals and nonfinite values`() throws {
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection.Row.Progress(used: 31, total: 0)
        }
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection.Row.Progress(used: 31, total: -5)
        }
        #expect(throws: ProviderDetailSection.ValidationError.self) {
            _ = try ProviderDetailSection.Row.Progress(used: .infinity, total: 100)
        }
    }

    @Test
    func `row id and progress round trip through codable`() throws {
        let row = try ProviderDetailSection.Row(
            id: "copilot-org-credits",
            label: "Org credits (example-org)",
            value: "81 / 6000",
            progress: ProviderDetailSection.Row.Progress(used: 81, total: 6000))

        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(ProviderDetailSection.Row.self, from: data)

        #expect(decoded == row)
    }

    @Test
    func `row without id and progress decodes from legacy payloads`() throws {
        let json = #"{"label":"Credits used","value":"31","secondaryValue":"Resets Sep 1"}"#

        let row = try JSONDecoder().decode(ProviderDetailSection.Row.self, from: Data(json.utf8))

        #expect(row.id == nil)
        #expect(row.progress == nil)
        #expect(row.label == "Credits used")
    }

    @Test
    func `current snapshot fixture decodes with empty details`() throws {
        let url = try #require(Bundle.module.url(
            forResource: "usage-snapshot-current",
            withExtension: "json",
            subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(UsageSnapshot.self, from: Data(contentsOf: url))

        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.identity?.providerID == .synthetic)
        #expect(snapshot.details.isEmpty)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("\"details\"") == false)
    }
}
