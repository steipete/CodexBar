import CodexBarCore
import Foundation
import Testing

@Suite
struct JetBrainsStatusProbeTests {
    @Test
    func parsesQuotaXMLWithTariffQuota() throws {
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
    func parsesQuotaXMLWithoutTariffQuota() throws {
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
    func calculatesUsagePercentageFromAvailable() {
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
    func calculatesUsagePercentageAtZero() {
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
    func calculatesUsagePercentageAtMax() {
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
    func handlesZeroMaximum() {
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
    func convertsToUsageSnapshot() throws {
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
    func usageSnapshotUsesRefillDateForReset() throws {
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
    func parsesIDEDirectory() {
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
    func expandsTildeInCustomPath() async throws {
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
    func handlesHTMLEntities() throws {
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
    func throwsOnMissingQuotaInfo() throws {
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
    func throwsOnEmptyQuotaInfo() throws {
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
}
