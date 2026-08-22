import CodexBarCore
import Foundation
import Testing

struct OpenCodexRouteDispatcherTests {
    @Test(arguments: [
        ("openai", OpenCodexRouteTarget.subscription(.codex)),
        ("xai", OpenCodexRouteTarget.tokenOnly),
        ("  XAI\n", OpenCodexRouteTarget.tokenOnly),
        ("opencode-go", OpenCodexRouteTarget.subscription(.opencodego)),
        ("kimi-coding", OpenCodexRouteTarget.subscription(.kimi)),
        ("deepseek", OpenCodexRouteTarget.subscription(.deepseek)),
        ("opencode-free", OpenCodexRouteTarget.tokenOnly),
        ("kimi", OpenCodexRouteTarget.unknown),
        ("anthropic", OpenCodexRouteTarget.unknown),
        ("unknown", OpenCodexRouteTarget.unknown),
        ("unknown-vendor", OpenCodexRouteTarget.unknown),
    ])
    func `provider routes to the expected subscription target`(
        provider: String,
        expected: OpenCodexRouteTarget)
    {
        #expect(OpenCodexRouteDispatcher.route(provider: provider) == expected)
    }

    @Test(arguments: [
        ("gpt-5.6-sol", true),
        ("openai/gpt-5.6-sol", true),
        ("opencode-go/deepseek-v4-flash", false),
        ("kimi-coding/k2p5", false),
    ])
    func `codex subscription attribution respects model route prefixes`(
        modelName: String,
        expected: Bool)
    {
        #expect(OpenCodexRouteDispatcher.countsTowardCodexSubscription(modelName: modelName) == expected)
    }

    @Test
    func `model prefix wins over a mismatched provider label`() {
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "openai",
                modelName: "opencode-go/deepseek-v4-flash") == .subscription(.opencodego))
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "opencode-go",
                modelName: "gpt-5.2") == .subscription(.opencodego))
    }

    @Test
    func `explicit xai model prefix routes to Grok only with OAuth evidence`() {
        #expect(
            OpenCodexRouteDispatcher.route(
                modelName: "xai/grok-4.6",
                oauthBackedProviderIDs: ["xai"]) == .subscription(.grok))
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "openai",
                modelName: "  xai/grok-4.6  ",
                oauthBackedProviderIDs: ["xai"]) == .subscription(.grok))
        #expect(OpenCodexRouteDispatcher.route(modelName: "xai/grok-4.6") == .tokenOnly)
    }

    @Test
    func `xai OAuth config routes to Grok`() throws {
        let context = try Self.authContext(configJSON: """
        {
          "providers": {
            "xai": { "baseUrl": "https://api.x.ai/v1", "authMode": "oauth" }
          }
        }
        """)

        #expect(context.authModes["xai"] == "oauth")
        #expect(context.oauthBackedProviderIDs == ["xai"])
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "xai",
                oauthBackedProviderIDs: context.oauthBackedProviderIDs) == .subscription(.grok))
    }

    @Test(arguments: ["apiKey", "forward", "oidc", "unknown"])
    func `xai non OAuth config stays token only`(authMode: String) throws {
        let context = try Self.authContext(configJSON: """
        { "providers": { "xai": { "authMode": "\(authMode)" } } }
        """)

        #expect(context.authModes["xai"] == authMode.lowercased())
        #expect(!context.oauthBackedProviderIDs.contains("xai"))
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: "xai",
                oauthBackedProviderIDs: context.oauthBackedProviderIDs) == .tokenOnly)
    }

    @Test
    func `xai routing fails closed without readable complete OAuth config`() throws {
        let cases: [(String, String?, Bool)] = [
            ("missing config", nil, false),
            ("unreadable config", nil, true),
            ("malformed JSON", "{not-json", false),
            ("missing xai provider", #"{"providers":{"openai":{"authMode":"oauth"}}}"#, false),
            ("missing auth mode", #"{"providers":{"xai":{"baseUrl":"https://api.x.ai/v1"}}}"#, false),
        ]

        for (label, configJSON, makeConfigDirectory) in cases {
            let context = try Self.authContext(
                configJSON: configJSON,
                makeConfigDirectory: makeConfigDirectory)
            #expect(
                OpenCodexRouteDispatcher.route(
                    provider: "xai",
                    oauthBackedProviderIDs: context.oauthBackedProviderIDs) == .tokenOnly,
                "Fail-closed case: \(label)")
        }
    }

    @Test(arguments: [
        ("openai", OpenCodexRouteTarget.subscription(.codex)),
        ("kimi-coding", OpenCodexRouteTarget.subscription(.kimi)),
        ("deepseek", OpenCodexRouteTarget.subscription(.deepseek)),
        ("opencode-go", OpenCodexRouteTarget.subscription(.opencodego)),
    ])
    func `non xai subscription routes ignore xai auth state`(
        provider: String,
        expected: OpenCodexRouteTarget)
    {
        #expect(OpenCodexRouteDispatcher.route(provider: provider) == expected)
        #expect(
            OpenCodexRouteDispatcher.route(
                provider: provider,
                oauthBackedProviderIDs: ["xai"]) == expected)
    }

    private struct AuthContext {
        let authModes: [String: String]
        let oauthBackedProviderIDs: Set<String>
    }

    private static func authContext(
        configJSON: String?,
        makeConfigDirectory: Bool = false) throws -> AuthContext
    {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodexRouteDispatcherTests-\(UUID().uuidString)", isDirectory: true)
        let openCodexHome = home.appendingPathComponent(".opencodex", isDirectory: true)
        try fileManager.createDirectory(at: openCodexHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let configURL = openCodexHome.appendingPathComponent("config.json", isDirectory: false)
        if makeConfigDirectory {
            try fileManager.createDirectory(at: configURL, withIntermediateDirectories: false)
        } else if let configJSON {
            try configJSON.write(to: configURL, atomically: true, encoding: .utf8)
        }
        let environment = ["OPENCODEX_HOME": openCodexHome.path]
        return AuthContext(
            authModes: OpenCodexUsageLog.providerAuthModes(
                environment: environment,
                homeDirectory: home),
            oauthBackedProviderIDs: OpenCodexUsageLog.oauthBackedProviderIDs(
                environment: environment,
                homeDirectory: home))
    }
}
