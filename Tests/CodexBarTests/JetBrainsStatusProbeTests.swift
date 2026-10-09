import Foundation
import Testing
@testable import CodexBarCore

struct JetBrainsStatusProbeTests {
    @Test(arguments: [false, true])
    func `auto-detect does not combine another IDE log with selected XML`(selectedHasLog: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let options = root.appendingPathComponent("DataGrip2026.2/options")
        try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let quotaPath = options.appendingPathComponent("AIAssistantQuotaManager2.xml")
        let xml = """
        <application><component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="{&quot;current&quot;:&quot;25&quot;,&quot;maximum&quot;:&quot;100&quot;}" />
          <option name="nextRefill" value="{&quot;next&quot;:&quot;2026-11-01T00:00:00Z&quot;}" />
        </component></application>
        """
        try Data(xml.utf8).write(to: quotaPath)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: quotaPath.path)
        let selected = JetBrainsIDEInfo(
            name: "DataGrip",
            version: "2026.2",
            basePath: options.deletingLastPathComponent().path,
            quotaFilePath: quotaPath.path)
        let other = JetBrainsIDEInfo(
            name: "PhpStorm",
            version: "2026.2",
            basePath: root.appendingPathComponent("PhpStorm2026.2").path,
            quotaFilePath: root.appendingPathComponent("PhpStorm2026.2/options/AIAssistantQuotaManager2.xml").path)
        let entry = JetBrainsQuotaLogReader.Entry(
            timestamp: Date(timeIntervalSince1970: 100),
            quotaInfo: .init(type: "Available", used: 50, maximum: 100, available: 50, until: nil),
            refillInfo: nil)
        let otherEntry = JetBrainsQuotaLogReader.Entry(
            timestamp: Date(timeIntervalSince1970: 200),
            quotaInfo: .init(type: "Available", used: 90, maximum: 100, available: 10, until: nil),
            refillInfo: .init(type: "Known", next: .distantFuture, amount: 100, duration: "30d"))
        let probe = JetBrainsStatusProbe(
            settings: nil,
            detectIDEs: { $0 ? [selected, other] : [selected] },
            readLogEntry: { $0 == selected.basePath ? (selectedHasLog ? entry : nil) : otherEntry })
        let snapshot = try await probe.fetch()
        #expect(snapshot.detectedIDE == selected)
        #expect(snapshot.quotaInfo.used == (selectedHasLog ? 50 : 25))
        #expect(snapshot.refillInfo?.next == (selectedHasLog ? nil : ISO8601DateParser.parse("2026-11-01T00:00:00Z")))
    }

    @Test
    func `parses quota XML with tariff quota`() throws {
        // Real-world format with tariffQuota containing available credits
        let quotaInfo = [
            "{&#10;  &quot;type&quot;: &quot;Available&quot;,",
            "&#10;  &quot;current&quot;: &quot;7478.3&quot;,",
            "&#10;  &quot;maximum&quot;: &quot;1000000&quot;,",
            "&#10;  &quot;until&quot;: &quot;2026-11-09T21:00:00Z&quot;,",
            "&#10;  &quot;tariffQuota&quot;: {",
            "&#10;    &quot;current&quot;: &quot;7478.3&quot;,",
            "&#10;    &quot;maximum&quot;: &quot;1000000&quot;,",
            "&#10;    &quot;available&quot;: &quot;992521.7&quot;",
            "&#10;  }&#10;}",
        ].joined()
        let nextRefill = [
            "{&#10;  &quot;type&quot;: &quot;Known&quot;,",
            "&#10;  &quot;next&quot;: &quot;2026-01-16T14:00:54.939Z&quot;,",
            "&#10;  &quot;tariff&quot;: {",
            "&#10;    &quot;amount&quot;: &quot;1000000&quot;,",
            "&#10;    &quot;duration&quot;: &quot;PT720H&quot;",
            "&#10;  }&#10;}",
        ].joined()

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option
              name="quotaInfo"
              value="\(quotaInfo)" />
            <option
              name="nextRefill"
              value="\(nextRefill)" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "Available")
        #expect(snapshot.quotaInfo.used == 7478.3)
        #expect(snapshot.quotaInfo.maximum == 1_000_000)
        #expect(snapshot.quotaInfo.available == 992_521.7)
        #expect(snapshot.quotaInfo.until != nil)

        #expect(snapshot.refillInfo?.type == "Known")
        #expect(snapshot.refillInfo?.amount == 1_000_000)
        #expect(snapshot.refillInfo?.duration == "PT720H")
        #expect(snapshot.refillInfo?.next != nil)
    }

    @Test
    func `parses quota XML without tariff quota`() throws {
        // Fallback format without tariffQuota
        let quotaInfo = [
            "{&#10;  &quot;type&quot;: &quot;paid&quot;,",
            "&#10;  &quot;current&quot;: &quot;50000&quot;,",
            "&#10;  &quot;maximum&quot;: &quot;100000&quot;,",
            "&#10;  &quot;until&quot;: &quot;2025-12-31T23:59:59Z&quot;&#10;}",
        ].joined()
        let nextRefill = [
            "{&#10;  &quot;type&quot;: &quot;monthly&quot;,",
            "&#10;  &quot;next&quot;: &quot;2025-01-01T00:00:00Z&quot;,",
            "&#10;  &quot;tariff&quot;: {",
            "&#10;    &quot;amount&quot;: &quot;100000&quot;,",
            "&#10;    &quot;duration&quot;: &quot;monthly&quot;",
            "&#10;  }&#10;}",
        ].joined()

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option
              name="quotaInfo"
              value="\(quotaInfo)" />
            <option
              name="nextRefill"
              value="\(nextRefill)" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "paid")
        #expect(snapshot.quotaInfo.used == 50000)
        #expect(snapshot.quotaInfo.maximum == 100_000)
        // Without tariffQuota, available is calculated as maximum - used
        #expect(snapshot.quotaInfo.available == 50000)
        #expect(snapshot.quotaInfo.until != nil)

        #expect(snapshot.refillInfo?.type == "monthly")
        #expect(snapshot.refillInfo?.amount == 100_000)
        #expect(snapshot.refillInfo?.duration == "monthly")
    }

    @Test
    func `calculates usage percentage from available`() {
        // available = 75_000, maximum = 100_000 -> 75% remaining, 25% used
        let quotaInfo = JetBrainsQuotaInfo(
            type: "paid",
            used: 25000,
            maximum: 100_000,
            available: 75000,
            until: nil)

        #expect(quotaInfo.usedPercent == 25.0)
        #expect(quotaInfo.remainingPercent == 75.0)
    }

    @Test
    func `calculates usage percentage at zero`() {
        let quotaInfo = JetBrainsQuotaInfo(
            type: "paid",
            used: 0,
            maximum: 100_000,
            available: 100_000,
            until: nil)

        #expect(quotaInfo.usedPercent == 0.0)
        #expect(quotaInfo.remainingPercent == 100.0)
    }

    @Test
    func `calculates usage percentage at max`() {
        let quotaInfo = JetBrainsQuotaInfo(
            type: "paid",
            used: 100_000,
            maximum: 100_000,
            available: 0,
            until: nil)

        #expect(quotaInfo.usedPercent == 100.0)
        #expect(quotaInfo.remainingPercent == 0.0)
    }

    @Test
    func `handles zero maximum`() {
        let quotaInfo = JetBrainsQuotaInfo(
            type: "free",
            used: 1000,
            maximum: 0,
            available: nil,
            until: nil)

        #expect(quotaInfo.usedPercent == 0.0)
        #expect(quotaInfo.remainingPercent == 100.0)
    }

    @Test
    func `converts to usage snapshot`() throws {
        let quotaInfo = JetBrainsQuotaInfo(
            type: "Available",
            used: 7478.3,
            maximum: 1_000_000,
            available: 992_521.7,
            until: Date().addingTimeInterval(3600))

        let refillInfo = JetBrainsRefillInfo(
            type: "Known",
            next: Date().addingTimeInterval(86400),
            amount: 1_000_000,
            duration: "PT720H")

        let ideInfo = JetBrainsIDEInfo(
            name: "IntelliJ IDEA",
            version: "2025.3",
            basePath: "/test/path",
            quotaFilePath: "/test/path/options/AIAssistantQuotaManager2.xml")

        let snapshot = JetBrainsStatusSnapshot(
            quotaInfo: quotaInfo,
            refillInfo: refillInfo,
            detectedIDE: ideInfo)

        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.primary != nil)
        // usedPercent should be approximately 0.75% (7_478.3 / 1_000_000 * 100)
        #expect(try #require(usage.primary?.usedPercent) < 1.0)
        // Reset date should come from refillInfo.next, not quotaInfo.until
        #expect(usage.primary?.resetsAt != nil)
        #expect(usage.secondary == nil)
        #expect(usage.identity?.providerID == .jetbrains)
        #expect(usage.identity?.accountOrganization == "IntelliJ IDEA 2025.3")
        #expect(usage.identity?.loginMethod == "Available")
    }

    @Test
    func `usage snapshot uses refill date for reset`() throws {
        let refillDate = Date().addingTimeInterval(86400 * 6) // 6 days from now
        let untilDate = Date().addingTimeInterval(86400 * 300) // 300 days from now

        let quotaInfo = JetBrainsQuotaInfo(
            type: "Available",
            used: 1000,
            maximum: 1_000_000,
            available: 999_000,
            until: untilDate)

        let refillInfo = JetBrainsRefillInfo(
            type: "Known",
            next: refillDate,
            amount: 1_000_000,
            duration: "PT720H")

        let snapshot = JetBrainsStatusSnapshot(
            quotaInfo: quotaInfo,
            refillInfo: refillInfo,
            detectedIDE: nil)

        let usage = try snapshot.toUsageSnapshot()

        // Reset date should be refillDate (6 days), not untilDate (300 days)
        #expect(usage.primary?.resetsAt == refillDate)
    }

    @Test
    func `parses IDE directory`() {
        let ides = [
            ("IntelliJIdea2024.3", "IntelliJ IDEA", "2024.3"),
            ("PyCharm2024.2", "PyCharm", "2024.2"),
            ("WebStorm2024.1", "WebStorm", "2024.1"),
            ("GoLand2024.3", "GoLand", "2024.3"),
            ("CLion2024.2", "CLion", "2024.2"),
            ("RustRover2024.3", "RustRover", "2024.3"),
        ]

        for (dirname, expectedName, expectedVersion) in ides {
            let info = JetBrainsIDEInfo(
                name: expectedName,
                version: expectedVersion,
                basePath: "/test/\(dirname)",
                quotaFilePath: "/test/\(dirname)/options/AIAssistantQuotaManager2.xml")

            #expect(info.name == expectedName)
            #expect(info.version == expectedVersion)
            #expect(info.displayName == "\(expectedName) \(expectedVersion)")
        }
    }

    @Test
    func `expands tilde in custom path`() async throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let testRoot = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Caches")
            .appendingPathComponent("CodexBarTests")
            .appendingPathComponent("JetBrains-\(UUID().uuidString)")
        let optionsDir = testRoot.appendingPathComponent("options")
        try fileManager.createDirectory(
            at: optionsDir,
            withIntermediateDirectories: true,
            attributes: nil)
        defer { try? fileManager.removeItem(at: testRoot) }

        let quotaInfo = [
            "{&quot;type&quot;:&quot;free&quot;",
            ",&quot;current&quot;:&quot;0&quot;",
            ",&quot;maximum&quot;:&quot;100000&quot;}",
        ].joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option
              name="quotaInfo"
              value="\(quotaInfo)" />
          </component>
        </application>
        """
        let quotaFile = optionsDir.appendingPathComponent("AIAssistantQuotaManager2.xml")
        try xml.write(to: quotaFile, atomically: true, encoding: .utf8)

        let tildePath: String
        if testRoot.path.hasPrefix(home.path) {
            let suffix = testRoot.path.dropFirst(home.path.count)
            tildePath = "~\(suffix)"
        } else {
            tildePath = testRoot.path
        }

        let settings = ProviderSettingsSnapshot.make(
            jetbrains: ProviderSettingsSnapshot.JetBrainsProviderSettings(ideBasePath: "  \(tildePath)  "))

        let probe = JetBrainsStatusProbe(settings: settings)
        let snapshot = try await probe.fetch()

        #expect(snapshot.quotaInfo.maximum == 100_000)
    }

    @Test
    func `handles HTML entities`() throws {
        let quotaInfo = [
            "{&quot;type&quot;:&quot;free&quot;",
            ",&quot;current&quot;:&quot;0&quot;",
            ",&quot;maximum&quot;:&quot;50000&quot;}",
        ].joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option
              name="quotaInfo"
              value="\(quotaInfo)" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "free")
        #expect(snapshot.quotaInfo.used == 0)
        #expect(snapshot.quotaInfo.maximum == 50000)
    }

    @Test
    func `throws on missing quota info`() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        #expect(throws: JetBrainsStatusProbeError.noQuotaInfo) {
            _ = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)
        }
    }

    @Test
    func `throws on empty quota info`() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option name="quotaInfo" value="" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        #expect(throws: JetBrainsStatusProbeError.noQuotaInfo) {
            _ = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)
        }
    }

    @Test
    func `uses monthly tariff quota when top-up credits inflate the overall maximum`() throws {
        let quotaInfo = [
            "{&#10;  &quot;type&quot;: &quot;Available&quot;,",
            "&#10;  &quot;current&quot;: &quot;346000&quot;,",
            "&#10;  &quot;maximum&quot;: &quot;6489986.397&quot;,",
            "&#10;  &quot;tariffQuota&quot;: {",
            "&#10;    &quot;current&quot;: &quot;346000&quot;,",
            "&#10;    &quot;maximum&quot;: &quot;1000000&quot;,",
            "&#10;    &quot;available&quot;: &quot;654000&quot;",
            "&#10;  },",
            "&#10;  &quot;topUpQuota&quot;: {",
            "&#10;    &quot;current&quot;: &quot;0&quot;,",
            "&#10;    &quot;maximum&quot;: &quot;5489986.397&quot;,",
            "&#10;    &quot;available&quot;: &quot;5489986.397&quot;",
            "&#10;  }",
            "&#10;}",
        ].joined()
        let xml = """
        <application>
          <component name="AIAssistantQuotaManager2">
            <option name="quotaInfo" value="\(quotaInfo)" />
          </component>
        </application>
        """

        let snapshot = try JetBrainsStatusProbe.parseXMLData(Data(xml.utf8), detectedIDE: nil)

        #expect(snapshot.quotaInfo.used == 346_000)
        #expect(snapshot.quotaInfo.maximum == 1_000_000)
        #expect(snapshot.quotaInfo.available == 654_000)
        #expect(abs(snapshot.quotaInfo.usedPercent - 34.6) < 0.001)
        #expect(abs(snapshot.quotaInfo.remainingPercent - 65.4) < 0.001)
        #expect(snapshot.quotaInfo.topUp == JetBrainsTopUpQuota(maximum: 5_489_986.397, available: 5_489_986.397))
    }

    @Test
    func `quota XML with top-up credits shows the remaining balance beside the monthly window`() throws {
        let quotaInfo = [
            "{&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:&quot;353265.849&quot;,",
            "&quot;maximum&quot;:&quot;6489986.397&quot;,",
            "&quot;tariffQuota&quot;:{&quot;current&quot;:&quot;353265.849&quot;,",
            "&quot;maximum&quot;:&quot;1000000&quot;,&quot;available&quot;:&quot;646734.151&quot;},",
            "&quot;topUpQuota&quot;:{&quot;current&quot;:&quot;0&quot;,",
            "&quot;maximum&quot;:&quot;5489986.397&quot;,&quot;available&quot;:&quot;5489986.397&quot;}}",
        ].joined()
        let xml = """
        <application><component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="\(quotaInfo)" />
        </component></application>
        """

        let usage = try JetBrainsStatusProbe.parseXMLData(Data(xml.utf8), detectedIDE: nil).toUsageSnapshot()

        #expect(abs((usage.primary?.remainingPercent ?? 0) - 64.6734151) < 0.0001)
        #expect(usage.secondary == nil)
        #expect(usage.details.first?.title == "Top-up credits")
        #expect(usage.detailRow(label: "Remaining")?.value == "54.90 credits")
    }

    @Test(arguments: [
        [String: String](),
        ["current": "0", "maximum": "0", "available": "0"],
        ["current": "0", "maximum": "abc", "available": "0"],
        ["current": "0", "maximum": "100", "available": "-1"],
    ])
    func `missing or empty top-up quota hides the top-up credits`(topUp: [String: String]) throws {
        var json: [String: Any] = [
            "type": "Available",
            "tariffQuota": ["current": "250000", "maximum": "1000000", "available": "750000"],
        ]
        if !topUp.isEmpty { json["topUpQuota"] = topUp }
        let encoded = try #require(String(bytes: JSONSerialization.data(withJSONObject: json), encoding: .utf8))
            .replacingOccurrences(of: "\"", with: "&quot;")
        let xml = """
        <application><component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="\(encoded)" />
        </component></application>
        """

        let snapshot = try JetBrainsStatusProbe.parseXMLData(Data(xml.utf8), detectedIDE: nil)

        #expect(snapshot.quotaInfo.topUp == nil)
        #expect(try snapshot.toUsageSnapshot().details.isEmpty)
    }

    @Test
    func `auto-detect falls back to idea log when no IDE has a quota XML`() async throws {
        let log = [
            "2026-10-05 15:21:27,386 [1]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota refill state is: "
                + "Known(next=2026-10-11T17:00:30.231Z, tariff=QuotaRefillInfoTariff(amount=1000000, duration=30d))",
            "2026-10-05 15:27:49,811 [2]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
                + "Available(current=346495.294, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
                + "tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706), "
                + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))",
        ].joined(separator: "\n")
        let logEntry = try #require(JetBrainsQuotaLogReader.latestEntry(inLogContent: log))
        let staleEntry = JetBrainsQuotaLogReader.Entry(
            timestamp: logEntry.timestamp.addingTimeInterval(-3600),
            quotaInfo: JetBrainsQuotaInfo(type: "Available", used: 0, maximum: 1_000_000, available: nil, until: nil),
            refillInfo: nil)
        let dataGrip = JetBrainsIDEInfo(
            name: "DataGrip",
            version: "2026.2",
            basePath: "/missing/DataGrip2026.2",
            quotaFilePath: "/missing/DataGrip2026.2/options/AIAssistantQuotaManager2.xml")
        let phpStorm = JetBrainsIDEInfo(
            name: "PhpStorm",
            version: "2026.2",
            basePath: "/missing/PhpStorm2026.2",
            quotaFilePath: "/missing/PhpStorm2026.2/options/AIAssistantQuotaManager2.xml")

        let probe = JetBrainsStatusProbe(
            settings: nil,
            detectIDEs: { includeMissingQuota in includeMissingQuota ? [dataGrip, phpStorm] : [] },
            readLogEntry: { basePath in basePath == dataGrip.basePath ? logEntry : staleEntry })
        let snapshot = try await probe.fetch()

        #expect(snapshot.detectedIDE == dataGrip)
        #expect(snapshot.quotaInfo.used == 346_495.294)
        #expect(snapshot.quotaInfo.maximum == 1_000_000)
        #expect(snapshot.refillInfo?.next == ISO8601DateParser.parse("2026-10-11T17:00:30.231Z"))
    }

    @Test
    func `auto-detect without quota XML or log still reports no IDE`() async {
        let ide = JetBrainsIDEInfo(
            name: "DataGrip",
            version: "2026.2",
            basePath: "/missing/DataGrip2026.2",
            quotaFilePath: "/missing/DataGrip2026.2/options/AIAssistantQuotaManager2.xml")
        let probe = JetBrainsStatusProbe(
            settings: nil,
            detectIDEs: { includeMissingQuota in includeMissingQuota ? [ide] : [] },
            readLogEntry: { _ in nil })

        await #expect(throws: JetBrainsStatusProbeError.noIDEDetected) {
            _ = try await probe.fetch()
        }
    }

    @Test(arguments: [
        ["current": "25000"],
        ["maximum": "100000"],
        ["current": "NaN", "maximum": "100000"],
        ["current": "25000", "maximum": "invalid"],
    ])
    func `incomplete monthly quota falls back to one consistent total balance`(monthly: [String: String]) throws {
        let quota: [String: Any] = [
            "type": "Available",
            "current": "50000",
            "maximum": "200000",
            "tariffQuota": monthly.merging(["available": "75000"]) { value, _ in value },
        ]
        let json = try JSONSerialization.data(withJSONObject: quota)
        let encoded = try #require(String(bytes: json, encoding: .utf8))
            .replacingOccurrences(of: "\"", with: "&quot;")
        let xml = """
        <application><component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="\(encoded)" />
        </component></application>
        """
        let snapshot = try JetBrainsStatusProbe.parseXMLData(Data(xml.utf8), detectedIDE: nil)

        #expect(snapshot.quotaInfo.used == 50000)
        #expect(snapshot.quotaInfo.maximum == 200_000)
        #expect(snapshot.quotaInfo.available == 150_000)
        #expect(snapshot.quotaInfo.usedPercent == 25)
        #expect(snapshot.quotaInfo.remainingPercent == 75)
    }

    @Test
    func `preserves flat refill fields ahead of nested tariff fields`() throws {
        let xml = """
        <application><component name="AIAssistantQuotaManager2">
          <option name="quotaInfo" value="{&quot;current&quot;:&quot;0&quot;,&quot;maximum&quot;:&quot;100&quot;}" />
          <option name="nextRefill"
            value="{&quot;type&quot;:&quot;Known&quot;,&quot;amount&quot;:&quot;200&quot;,
            &quot;duration&quot;:&quot;PT720H&quot;,&quot;tariff&quot;:{&quot;amount&quot;:&quot;100&quot;,
            &quot;duration&quot;:&quot;PT24H&quot;}}" />
        </component></application>
        """
        let snapshot = try JetBrainsStatusProbe.parseXMLData(Data(xml.utf8), detectedIDE: nil)

        #expect(snapshot.refillInfo?.type == "Known")
        #expect(snapshot.refillInfo?.amount == 200)
        #expect(snapshot.refillInfo?.duration == "PT720H")
    }
}
