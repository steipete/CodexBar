import CodexBarCore
import Foundation
import Testing

/// Removing both quotes with mutating String operations formerly trapped on a lone quote.
struct SettingsReaderQuoteUnwrapTrapTests {
    @Test
    func `Alibaba cookie rejects a lone double quote`() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "\""]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == nil)
    }

    @Test
    func `Alibaba cookie rejects a lone apostrophe`() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "'"]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == nil)
    }

    @Test
    func `Alibaba cookie unwraps double quotes`() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "\"abc=def\""]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == "abc=def")
    }

    @Test
    func `Alibaba cookie unwraps single quotes`() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "'abc=def'"]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == "abc=def")
    }

    @Test
    func `Ollama API key rejects a lone double quote`() {
        for key in OllamaAPISettingsReader.apiKeyEnvironmentKeys {
            let env = [key: "\""]
            #expect(OllamaAPISettingsReader.apiKey(environment: env) == nil)
        }
    }

    @Test
    func `Ollama API key rejects a lone apostrophe`() {
        for key in OllamaAPISettingsReader.apiKeyEnvironmentKeys {
            let env = [key: "'"]
            #expect(OllamaAPISettingsReader.apiKey(environment: env) == nil)
        }
    }

    @Test
    func `Ollama API key unwraps quotes`() {
        let env = [OllamaAPISettingsReader.apiKeyEnvironmentKeys[0]: "\"sk-token\""]
        #expect(OllamaAPISettingsReader.apiKey(environment: env) == "sk-token")
    }

    @Test
    func `llmman API key rejects lone quotes and unwraps quotes`() {
        for value in ["\"", "'"] {
            #expect(LLMManSettingsReader.apiKey(environment: [LLMManSettingsReader.apiKeyEnvironmentKey: value]) == nil)
        }
        let env = [LLMManSettingsReader.apiKeyEnvironmentKey: "\"sk-token\""]
        #expect(LLMManSettingsReader.apiKey(environment: env) == "sk-token")
    }
}
