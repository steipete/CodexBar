import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct JetBrainsTopUpIntegrationTests {
    /// Quota shapes from #4287 (XML) and #4288 (log), with no account data.
    private static let logLine =
        "2026-10-05 15:30:55,732 [   8326] INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
            + "Available(current=346495.294, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
            + "tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706), "
            + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))"

    static func xml(available: String? = "5489986.397", current: String = "0") throws -> JetBrainsStatusSnapshot {
        var topUp = ["current": current, "maximum": "5489986.397"]
        topUp["available"] = available
        let json: [String: Any] = [
            "type": "Available", "current": "68433.145", "maximum": "6489986.397",
            "tariffQuota": ["current": "68433.145", "maximum": "1000000", "available": "931566.855"],
            "topUpQuota": topUp,
        ]
        let encoded = try #require(String(data: JSONSerialization.data(withJSONObject: json), encoding: .utf8))
            .replacingOccurrences(of: "\"", with: "&quot;")
        return try JetBrainsStatusProbe.parseXMLData(Data("""
        <application><component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="\(encoded)" />
        </component></application>
        """.utf8), detectedIDE: nil)
    }

    @Test func `XML and log report the same purchased balance without changing monthly usage`() throws {
        let xml = try Self.xml().toUsageSnapshot()
        let log = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: Self.logLine))
        let usage = try JetBrainsStatusSnapshot(
            quotaInfo: log.quotaInfo, refillInfo: log.refillInfo, detectedIDE: nil).toUsageSnapshot()
        #expect(xml.detailRow(label: "Remaining")?.value == "54.90 credits")
        #expect(usage.details == xml.details)
        #expect(abs((xml.primary?.usedPercent ?? 0) - 6.8433145) < 0.0001)
        #expect(abs((usage.primary?.usedPercent ?? 0) - 34.6495294) < 0.0001)
        #expect(xml.secondary == nil && usage.secondary == nil)
    }

    @Test(arguments: [nil, -1.0, 0.0, 1.0] as [Double?])
    func `freshness selects monthly and top-up balances together`(xmlOffset: Double?) throws {
        let xml = try Self.xml(available: "2000000", current: "3489986.397")
        let log = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: Self.logLine))
        let usage = try JetBrainsStatusProbe.applyingLogEntry(
            log, to: xml, quotaFileModifiedAt: xmlOffset.map { log.timestamp.addingTimeInterval($0) })
            .toUsageSnapshot()
        let useLog = xmlOffset == -1
        #expect(usage.detailRow(label: "Remaining")?.value == (useLog ? "54.90 credits" : "20.00 credits"))
        #expect(abs((usage.primary?.usedPercent ?? 0) - (useLog ? 34.6495294 : 6.8433145)) < 0.0001)
    }

    @Test func `newer log without top-ups clears the older XML balance`() throws {
        let line = Self.logLine.replacingOccurrences(
            of: ", topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397)", with: "")
        let log = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: line))
        let usage = try JetBrainsStatusProbe.applyingLogEntry(
            log, to: Self.xml(), quotaFileModifiedAt: log.timestamp.addingTimeInterval(-1)).toUsageSnapshot()
        #expect(usage.details.isEmpty)
        #expect(abs((usage.primary?.usedPercent ?? 0) - 34.6495294) < 0.0001)
    }

    @Test(arguments: [nil, "abc", "nan", "inf", "-1"] as [String?])
    func `missing or invalid reported balance is never reconstructed`(available: String?) throws {
        #expect(try Self.xml(available: available).toUsageSnapshot().details.isEmpty)
    }

    @Test func `exhausted purchased balance remains visible`() throws {
        #expect(try Self.xml(available: "0", current: "5489986.397").toUsageSnapshot().detailRow(label: "Remaining")?
            .value == "0.00 credits")
    }

    @Test func `render synthetic production card when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_JETBRAINS_CARD_PROOF"] else { return }
        let usage = try Self.xml().toUsageSnapshot()
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .jetbrains,
            metadata: #require(ProviderDefaults.metadata[.jetbrains]),
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: usage.updatedAt))
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 16) {
            Text("Synthetic JetBrains quota").font(.caption)
            UsageMenuCardView(model: model, width: 340)
        }.padding(20).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
