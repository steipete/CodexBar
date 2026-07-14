import CodexBarCore
import Foundation
import Testing

struct AnyRouterSettingsReaderTests {
    @Test
    func `reads ANYROUTER_API_KEY`() {
        let env = ["ANYROUTER_API_KEY": "sk-ar-v1-abc"]
        #expect(AnyRouterSettingsReader.apiKey(environment: env) == "sk-ar-v1-abc")
    }

    @Test
    func `trims whitespace and strips quotes`() {
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "  sk-ar-v1-a  "]) == "sk-ar-v1-a")
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "\"sk-ar-v1-b\""]) == "sk-ar-v1-b")
        #expect(AnyRouterSettingsReader.apiKey(environment: ["ANYROUTER_API_KEY": "'sk-ar-v1-c'"]) == "sk-ar-v1-c")
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
