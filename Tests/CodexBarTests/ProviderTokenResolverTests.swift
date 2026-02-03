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
    func warpResolutionUsesEnvironmentToken() {
        let env = ["WARP_API_KEY": "wk-test-token"]
        let resolution = ProviderTokenResolver.warpResolution(environment: env)
        #expect(resolution?.token == "wk-test-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func warpResolutionTrimsToken() {
        let env = ["WARP_API_KEY": "  wk-token  "]
        let resolution = ProviderTokenResolver.warpResolution(environment: env)
        #expect(resolution?.token == "wk-token")
    }

    @Test
    func warpResolutionReturnsNilWhenMissing() {
        let env: [String: String] = [:]
        let resolution = ProviderTokenResolver.warpResolution(environment: env)
        #expect(resolution == nil)
    }
}
