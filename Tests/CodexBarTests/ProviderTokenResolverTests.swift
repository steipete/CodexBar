import CodexBarCore
import Testing

@Suite
struct ProviderTokenResolverTests {
    @Test
    func zaiResolutionUsesEnvironmentToken() {
        let env = [ZaiSettingsReader.apiTokenKey: "token"]
        let resolution = ProviderTokenResolver.zaiResolution(environment: env)
        #expect(resolution?.token == "token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func copilotResolutionTrimsToken() {
        let env = ["COPILOT_API_TOKEN": "  token  "]
        let resolution = ProviderTokenResolver.copilotResolution(environment: env)
        #expect(resolution?.token == "token")
    }

    @Test
    func poeResolutionUsesEnvironmentToken() {
        let env = ["POE_API_KEY": "sk-poe-token"]
        let resolution = ProviderTokenResolver.poeResolution(environment: env)
        #expect(resolution?.token == "sk-poe-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func poeResolutionTrimsToken() {
        let env = ["POE_API_KEY": "  sk-poe-token  "]
        let resolution = ProviderTokenResolver.poeResolution(environment: env)
        #expect(resolution?.token == "sk-poe-token")
    }

    @Test
    func poeResolutionReturnsNilForEmptyToken() {
        let env = ["POE_API_KEY": "   "]
        let resolution = ProviderTokenResolver.poeResolution(environment: env)
        #expect(resolution == nil)
    }

    @Test
    func poeResolutionReturnsNilForMissingKey() {
        let env: [String: String] = [:]
        let resolution = ProviderTokenResolver.poeResolution(environment: env)
        #expect(resolution == nil)
    }
}
