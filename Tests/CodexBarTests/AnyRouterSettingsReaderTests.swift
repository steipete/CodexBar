import CodexBarCore
import Foundation
import Testing

struct AnyRouterSettingsReaderTests {
    @Test
    func `reads ANYROUTER_API_KEY`() {
        let env = ["ANYROUTER_API_KEY": "ak_abc"]
        #expect(AnyRouterSettingsReader.apiKey(environment: env) == "ak_abc")
    }

    @Test
    func `token account copy requests a management key`() throws {
        let support = try #require(TokenAccountSupportCatalog.support(for: .anyrouter))

        #expect(support.title == "Management keys")
        #expect(support.subtitle.contains("management key"))
        #expect(support.subtitle.contains("read:credits"))
        #expect(support.placeholder.contains("ak_"))
        #expect(!support.placeholder.contains("sk-ar-v1"))
        #expect(TokenAccountSupportCatalog.envOverride(for: .anyrouter, token: "ak_abc") == [
            "ANYROUTER_API_KEY": "ak_abc",
        ])
    }

    @Test
    func `trims whitespace and strips quotes`() {
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "  ak_a  "]) == "ak_a")
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "\"ak_b\""]) == "ak_b")
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "'ak_c'"]) == "ak_c")
    }

    @Test
    func `returns nil when key is absent or empty`() {
        #expect(AnyRouterSettingsReader.apiKey(environment: [:]) == nil)
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "  "]) == nil)
    }

    @Test
    func `defaults to the AnyRouter gateway`() {
        #expect(AnyRouterSettingsReader.baseURL(environment: [:]).absoluteString == "https://anyrouter.dev/api/v1")
    }

    @Test
    func `accepts an HTTPS base URL override`() {
        let env = ["ANYROUTER_API_URL": "https://gateway.example.com/api/v1"]
        #expect(
            AnyRouterSettingsReader.baseURL(environment: env).absoluteString
                == "https://gateway.example.com/api/v1")
        #expect(throws: Never.self) {
            try AnyRouterSettingsReader.validateEndpointOverride(environment: env)
        }
    }

    @Test
    func `rejects a plaintext HTTP base URL override`() {
        let env = ["ANYROUTER_API_URL": "http://gateway.example.com/api/v1"]
        #expect(throws: AnyRouterSettingsError.invalidEndpointOverride("ANYROUTER_API_URL")) {
            try AnyRouterSettingsReader.validateEndpointOverride(environment: env)
        }
    }

    @Test
    func `validation passes when no override is set`() {
        #expect(throws: Never.self) {
            try AnyRouterSettingsReader.validateEndpointOverride(environment: [:])
        }
    }
}
