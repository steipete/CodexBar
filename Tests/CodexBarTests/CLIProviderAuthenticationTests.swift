import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIProviderAuthenticationTests {
    @Test
    func `inventory describes supported inputs without reading credentials`() throws {
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .openai, apiKey: "synthetic-secret-never-in-inventory"),
            ProviderConfig(id: .copilot, cookieHeader: "synthetic-cookie-never-in-inventory"),
            ProviderConfig(id: .azureopenai),
        ])
        let results = CodexBarCLI.configProviderStatuses(config)
        let openai = try #require(results.first { $0.provider == "openai" }?.authentication)
        #expect(openai.supportsConfigAPIKey)
        #expect(openai.environmentVariables.contains("OPENAI_ADMIN_KEY"))
        let copilot = try #require(results.first { $0.provider == "copilot" }?.authentication)
        #expect(copilot.sourceModes == ["api", "auto"])
        #expect(copilot.supportsConfigCookieHeader)
        #expect(copilot.loginCommand == "codexbar config login --provider copilot")
        #expect(copilot.tokenAccounts?.setupHint == CopilotProviderDescriptor.descriptor.credentials?
            .tokenAccountSupport?.subtitle)
        let azure = try #require(results.first { $0.provider == "azureopenai" }?.authentication)
        #expect(azure.environmentVariables.contains("AZURE_OPENAI_ENDPOINT"))
        #expect(azure.environmentVariables.contains("AZURE_OPENAI_DEPLOYMENT_NAME"))
        let data = try JSONEncoder().encode(results)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("synthetic-secret-never-in-inventory"))
        #expect(!json.contains("synthetic-cookie-never-in-inventory"))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.allSatisfy { $0["enabled"] != nil && $0["defaultEnabled"] != nil })
        #expect(objects.first { $0["provider"] as? String == "openai" }?["authentication"] is [String: Any])
    }
}
