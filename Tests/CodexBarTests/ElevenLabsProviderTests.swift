import Foundation
import Testing
@testable import CodexBarCore

struct ElevenLabsProviderTests {
    @Test
    func `descriptor is script only with either prototype flag`() async throws {
        for flag in ["0", "1"] {
            let context = Self.context(["XI_API_KEY": " xi-test ", "CODEXBAR_JS_PROVIDERS": flag])
            let strategies = await ElevenLabsProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
            #expect(strategies.map(\.id) == ["elevenlabs.js"])
            let strategy = try #require(strategies.first)
            #expect(await strategy.isAvailable(context))
            #expect(ElevenLabsProviderDescriptor.scriptValues(environment: context.env)?
                .secrets["ELEVENLABS_API_KEY"] == "xi-test")
        }
    }

    @Test(arguments: [
        ("https://elevenlabs.test", "https://elevenlabs.test/v1/user/subscription"),
        ("https://elevenlabs.test/v1/", "https://elevenlabs.test/v1/user/subscription"),
        ("elevenlabs.test/proxy", "https://elevenlabs.test/proxy/v1/user/subscription"),
        ("https://elevenlabs.test/v1/?fixture=1", "https://elevenlabs.test/v1/user/subscription?fixture=1"),
        ("https://[::1]:8443/v1", "https://[::1]:8443/v1/user/subscription"),
    ])
    func `endpoint construction preserves native override paths`(base: String, expected: String) throws {
        let environment = ["ELEVENLABS_API_KEY": "xi-test", "ELEVENLABS_API_URL": base]
        let values = try #require(ElevenLabsProviderDescriptor.scriptValues(environment: environment))
        #expect(values.settings["BASE_URL"] == expected)
    }

    @Test
    func `invalid override fails before plugin loading or HTTP`() async throws {
        let context = Self.context(["ELEVENLABS_API_KEY": "xi-test", "ELEVENLABS_API_URL": "http://attacker.test/v1"])
        let strategy = try #require(await ElevenLabsProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(context).first)
        await #expect(throws: ElevenLabsSettingsError.invalidEndpointOverride("ELEVENLABS_API_URL")) {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `blank keys preserve missing credential message before request`() async throws {
        let context = Self.context(["ELEVENLABS_API_KEY": " \n "])
        let descriptor = ElevenLabsProviderDescriptor.descriptor
        let strategy = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first)
        #expect(await strategy.isAvailable(context) == false)
        await #expect(throws: ProviderFetchClassifiedError(
            kind: .missingCredential,
            message: "Missing ElevenLabs API key. Set apiKey in ~/.codexbar/config.json or ELEVENLABS_API_KEY."))
        {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `primary key still wins over alias`() throws {
        let values = try #require(ElevenLabsProviderDescriptor.scriptValues(environment: [
            "ELEVENLABS_API_KEY": "primary", "XI_API_KEY": "alias",
        ]))
        #expect(values.secrets["ELEVENLABS_API_KEY"] == "primary")
        #expect(values.settings["BASE_URL"] == "https://api.elevenlabs.io/v1/user/subscription")
    }

    private static func context(_ environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ElevenLabsStubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private struct ElevenLabsStubClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String { "unused" }
    func detectVersion() -> String? { nil }
}
