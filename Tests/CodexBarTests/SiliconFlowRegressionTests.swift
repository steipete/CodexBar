import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SiliconFlowRegressionTests {
    @Test
    func `invalid configured origin offers no API key link`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(
            suite: "SiliconFlowRegressionTests-invalid-origin")
        fixture.settings[providerConfig: .siliconflow, field: .endpoint] = "https://untrusted.example"
        let implementation = try #require(ProviderCatalog.implementation(for: .siliconflow))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .siliconflow))
        let keyField = try #require(fields.first { $0.id == "siliconflow-api-key" })
        #expect(keyField.actions.isEmpty)
    }

    @Test
    func `official SiliconFlow symbol is shared across app website and serve`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let svg = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/Resources/ProviderIcon-siliconflow.svg"),
            encoding: .utf8)
        #expect(svg.contains("M50.7172 0H27.6622"))
        #expect(svg.contains("fill=\"currentColor\""))
        let website = try String(
            contentsOf: root.appendingPathComponent("docs/logos/siliconflow.svg"),
            encoding: .utf8)
        #expect(website == svg)
        let cli = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBarCLI/CLIServeProviderIcons.swift"),
            encoding: .utf8)
        #expect(cli.contains("\"ProviderIcon-siliconflow\": \"\(Data(svg.utf8).base64EncodedString())\""))
    }
}
