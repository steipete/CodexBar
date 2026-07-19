import CodexBarCore
import Foundation
import Testing

/// Tests for the regex-based JetBrains XML parser used on Linux.
/// These tests verify that the non-libxml2 implementation correctly parses
/// JetBrains AI Assistant quota files.
@Suite
struct JetBrainsParserLinuxTests {
    @Test
    func parsesQuotaXMLWithBothOptions() throws {
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
            <option name="quotaInfo" value="\(quotaInfo)" />
            <option name="nextRefill" value="\(nextRefill)" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "Available")
        #expect(snapshot.quotaInfo.used == 7478.3)
        #expect(snapshot.quotaInfo.maximum == 1_000_000)
        #expect(snapshot.quotaInfo.available == 992_521.7)
        #expect(snapshot.refillInfo?.type == "Known")
        #expect(snapshot.refillInfo?.amount == 1_000_000)
    }

    @Test
    func parsesQuotaXMLWithOnlyQuotaInfo() throws {
        let quotaInfo = "{&quot;type&quot;:&quot;free&quot;,&quot;current&quot;:&quot;5000&quot;,&quot;maximum&quot;:&quot;100000&quot;}"

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option name="quotaInfo" value="\(quotaInfo)" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "free")
        #expect(snapshot.quotaInfo.used == 5000)
        #expect(snapshot.quotaInfo.maximum == 100_000)
        #expect(snapshot.refillInfo == nil)
    }

    @Test
    func parsesXMLWithReversedAttributeOrder() throws {
        // Test that parser handles value before name (different attribute order)
        let quotaInfo = "{&quot;type&quot;:&quot;paid&quot;,&quot;current&quot;:&quot;1000&quot;,&quot;maximum&quot;:&quot;50000&quot;}"

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option value="\(quotaInfo)" name="quotaInfo" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "paid")
        #expect(snapshot.quotaInfo.used == 1000)
        #expect(snapshot.quotaInfo.maximum == 50000)
    }

    @Test
    func handlesHTMLEntities() throws {
        let quotaInfo = [
            "{&quot;type&quot;:&quot;test&quot;",
            ",&quot;current&quot;:&quot;0&quot;",
            ",&quot;maximum&quot;:&quot;50000&quot;}",
        ].joined()

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="AIAssistantQuotaManager2">
            <option name="quotaInfo" value="\(quotaInfo)" />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "test")
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
    func throwsOnMissingComponent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name="SomeOtherComponent">
            <option name="quotaInfo" value="{}" />
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

    @Test
    func parsesXMLWithSingleQuotes() throws {
        let quotaInfo = "{&quot;type&quot;:&quot;single&quot;,&quot;current&quot;:&quot;100&quot;,&quot;maximum&quot;:&quot;10000&quot;}"

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <application>
          <component name='AIAssistantQuotaManager2'>
            <option name='quotaInfo' value='\(quotaInfo)' />
          </component>
        </application>
        """

        let data = Data(xml.utf8)
        let snapshot = try JetBrainsStatusProbe.parseXMLData(data, detectedIDE: nil)

        #expect(snapshot.quotaInfo.type == "single")
        #expect(snapshot.quotaInfo.maximum == 10000)
    }
}
