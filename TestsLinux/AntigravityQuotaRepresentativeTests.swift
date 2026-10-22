import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityQuotaRepresentativeTests {
    private let presentation = AntigravityProviderDescriptor.descriptor.presentation

    @Test(arguments: ["gemini-weekly", "gemini_weekly", "gemini-weekly limit"])
    func `ordinary Gemini quota represents availability beside exhausted model quota`(ordinaryID: String) throws {
        let usage = try self.usage(buckets: [
            self.bucket(id: ordinaryID, remaining: 0.9996),
            self.bucket(id: "gemini-synthetic-limited-weekly", remaining: 0),
            self.bucket(id: "gemini-synthetic-special-weekly", remaining: 0.1),
        ])
        let primary = try #require(usage.primary)
        #expect(abs(primary.usedPercent - 0.04) < 0.000001)
        #expect(primary.windowMinutes == 10080)
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_900_000_000))
        let rows = try #require(usage.extraRateWindows)
        #expect(rows.count == 3)
        #expect(rows.first { $0.id.hasSuffix("synthetic-limited-weekly") }?.window.usedPercent == 100)
        #expect(self.presentation.semanticWindows(snapshot: usage).weekly?.usedPercent == 100)
        #expect(self.iconWindows(usage).secondary?.usedPercent == 100)
        guard case let .resolved(window) = self.presentation.menuBarWindow(context: .init(
            metric: .primary,
            snapshot: usage,
            supportsAverage: false,
            prioritizesExhaustedQuotas: false,
            now: usage.updatedAt))
        else { Issue.record("Expected a resolved primary metric"); return }
        #expect(window == primary)
    }

    @Test
    func `stable ordinary bucket ID wins even when group title changes`() throws {
        let usage = try self.usage(buckets: [
            self.bucket(id: "gemini-weekly", remaining: 0.8),
            self.bucket(id: "gemini-synthetic-limited-weekly", remaining: 0),
        ], groupName: "General models")
        #expect(usage.primary?.remainingPercent == 80)
        #expect(self.presentation.semanticWindows(snapshot: usage).weekly?.remainingPercent == 0)
    }

    @Test(arguments: ["absent", "unknown", "disabled"])
    func `model specific quota remains a fallback without measured ordinary quota`(ordinaryState: String) throws {
        var buckets = [self.bucket(id: "gemini-synthetic-limited-weekly", remaining: 0.25)]
        if ordinaryState != "absent" {
            buckets.append(self.bucket(
                id: "gemini-weekly",
                remaining: ordinaryState == "unknown" ? nil : 1,
                disabled: ordinaryState == "disabled"))
        }
        let usage = try self.usage(buckets: buckets)
        #expect(usage.primary?.remainingPercent == 25)
        #expect(self.presentation.semanticWindows(snapshot: usage).weekly?.remainingPercent == 25)
        #expect(self.iconWindows(usage).secondary?.remainingPercent == 25)
        #expect(usage.extraRateWindows?.count == buckets.count)
    }

    @Test
    func `cadence and icon selection retain the most constrained model quota`() throws {
        let usage = try self.usage(buckets: [
            self.bucket(id: "gemini-5h", remaining: 0.6, cadence: "5h"),
            self.bucket(id: "gemini-weekly", remaining: 0.9),
            self.bucket(id: "gemini-synthetic-limited-weekly", remaining: 0),
            self.bucket(id: "3p-weekly", remaining: 0.7),
        ])
        #expect(usage.primary?.remainingPercent == 60)
        #expect(usage.primary?.windowMinutes == 300)
        let semantic = self.presentation.semanticWindows(snapshot: usage)
        #expect(semantic.session?.remainingPercent == 60)
        #expect(semantic.weekly?.remainingPercent == 0)
        #expect(self.iconWindows(usage).primary == semantic.session)
        #expect(self.iconWindows(usage).secondary == semantic.weekly)
    }

    @Test
    func `ordinary session does not erase model specific weekly fallback`() throws {
        let usage = try self.usage(buckets: [
            self.bucket(id: "gemini-5h", remaining: 0.8, cadence: "5h"),
            self.bucket(id: "gemini-synthetic-limited-weekly", remaining: 0.1),
        ])
        #expect(usage.primary?.remainingPercent == 80)
        #expect(self.presentation.semanticWindows(snapshot: usage).weekly?.remainingPercent == 10)
        #expect(self.iconWindows(usage).secondary?.remainingPercent == 10)
    }

    @Test
    func `equal cadence buckets and groups retain source order`() throws {
        let groups: [[String: Any]] = [
            ["name": "Gemini first", "buckets": [
                self.bucket(id: "gemini-z-weekly", remaining: 0.7),
                self.bucket(id: "gemini-a-weekly", remaining: 0.8),
            ]],
            ["name": "Gemini second", "buckets": [self.bucket(id: "gemini-b-weekly", remaining: 0.9)]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["groups": groups])
        let usage = try AntigravityStatusProbe.parseQuotaSummaryResponse(data).toUsageSnapshot()
        #expect(usage.extraRateWindows?.map(\.id) == [
            "antigravity-quota-summary-gemini-z-weekly",
            "antigravity-quota-summary-gemini-a-weekly",
            "antigravity-quota-summary-gemini-b-weekly",
        ])
    }

    @Test
    func `unknown quota never becomes a measured zero`() throws {
        let usage = try self.usage(buckets: [self.bucket(id: "gemini-weekly", remaining: nil)])
        #expect(usage.primary == nil)
        #expect(self.presentation.semanticWindows(snapshot: usage).weekly == nil)
        #expect(self.iconWindows(usage).secondary == nil)
        #expect(usage.extraRateWindows?.first?.usageKnown == false)
    }

    @Test
    func `legacy Gemini model quota keeps its representative and reset`() throws {
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        let usage = try AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelId: "gemini-2.5-pro",
                    remainingFraction: 0.4,
                    resetTime: reset,
                    resetDescription: "Synthetic reset"),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local).toUsageSnapshot()
        #expect(usage.primary?.remainingPercent == 40)
        #expect(usage.primary?.resetsAt == reset)
    }

    private func iconWindows(_ usage: UsageSnapshot) -> ProviderUsageWindowPair {
        self.presentation.iconWindows(context: .init(
            snapshot: usage, secondaryOverrideWindowID: nil, now: usage.updatedAt))
    }

    private func bucket(
        id: String, remaining: Double?, cadence: String = "weekly", disabled: Bool = false) -> [String: Any]
    {
        var bucket: [String: Any] = [
            "id": id, "name": "Synthetic quota", "window": cadence, "disabled": disabled,
            "reset_time": "2030-03-17T17:46:40Z",
        ]
        if let remaining { bucket["remaining_fraction"] = remaining }
        return bucket
    }

    private func usage(buckets: [[String: Any]], groupName: String = "Gemini Models") throws -> UsageSnapshot {
        let quota: [String: Any] = ["groups": [["name": groupName, "buckets": buckets]]]
        let report: [String: Any] = [
            "status": "SUCCESS",
            "command": ["name": "usage", "data": quota],
        ]
        let data = try JSONSerialization.data(withJSONObject: report)
        if buckets.allSatisfy({ $0["remaining_fraction"] == nil }) {
            return try AntigravityStatusProbe.parseQuotaSummaryResponse(
                JSONSerialization.data(withJSONObject: quota)).toUsageSnapshot()
        }
        return try AntigravityStatusProbe.parseCLIUsageReport(data).toUsageSnapshot()
    }
}
