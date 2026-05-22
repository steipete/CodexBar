import CodexBarCore
import Foundation
import Testing

/// Regression tests for a copy-pasted quote-unwrap helper that traps on length-1 input.
///
/// 32 provider settings readers (plus `CodexBarConfig` and `CLIConfigCommand`) share a
/// `cleaned(_:)` helper of the form:
///
///     if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
///         (value.hasPrefix("'") && value.hasSuffix("'"))
///     {
///         value.removeFirst()
///         value.removeLast()
///     }
///
/// For a value of length 1 (the single character `"` or `'`), both `hasPrefix` and
/// `hasSuffix` return true, `removeFirst()` empties the string, and `removeLast()` then
/// traps with "Can't remove last element from empty collection." This is reachable from
/// a misconfigured env var (e.g. `ALIBABA_TOKEN_PLAN_COOKIE='"'`) and from quoted JSON
/// values in `~/.codexbar/config.json`, both of which are user-controllable.
///
/// These tests exercise two representative public readers — Alibaba Token Plan (the
/// newest addition in #1098) and the Ollama API key reader (added in #1087) — by
/// passing the trap-inducing single-quote inputs and asserting the readers return nil
/// instead of crashing. The patch swaps `removeFirst()/removeLast()` for
/// `String(value.dropFirst().dropLast())`, which is empty-safe.
@Suite
struct SettingsReaderQuoteUnwrapTrapTests {
    @Test
    func alibabaTokenPlanCookieHeader_returnsNilForLoneDoubleQuoteValue() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "\""]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == nil)
    }

    @Test
    func alibabaTokenPlanCookieHeader_returnsNilForLoneApostropheValue() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "'"]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == nil)
    }

    @Test
    func alibabaTokenPlanCookieHeader_unwrapsProperlyDoubleQuotedValue() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "\"abc=def\""]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == "abc=def")
    }

    @Test
    func alibabaTokenPlanCookieHeader_unwrapsProperlySingleQuotedValue() {
        let env = [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "'abc=def'"]
        #expect(AlibabaTokenPlanSettingsReader.cookieHeader(environment: env) == "abc=def")
    }

    @Test
    func ollamaAPIKey_returnsNilForLoneDoubleQuoteValue() {
        for key in OllamaAPISettingsReader.apiKeyEnvironmentKeys {
            let env = [key: "\""]
            #expect(OllamaAPISettingsReader.apiKey(environment: env) == nil)
        }
    }

    @Test
    func ollamaAPIKey_returnsNilForLoneApostropheValue() {
        for key in OllamaAPISettingsReader.apiKeyEnvironmentKeys {
            let env = [key: "'"]
            #expect(OllamaAPISettingsReader.apiKey(environment: env) == nil)
        }
    }

    @Test
    func ollamaAPIKey_unwrapsProperlyQuotedValue() {
        let env = [OllamaAPISettingsReader.apiKeyEnvironmentKeys[0]: "\"sk-token\""]
        #expect(OllamaAPISettingsReader.apiKey(environment: env) == "sk-token")
    }
}
