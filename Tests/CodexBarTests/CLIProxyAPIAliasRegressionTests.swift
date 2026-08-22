import Foundation
import Testing
@testable import CodexBarCore

struct CLIProxyAPIAliasRegressionTests {
    @Test
    func `codex oauth model and alias do not prove a proxy route`() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-alias-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeCodexAliasConfiguration(to: root, fileManager: fileManager)
        let resolver = try CLIProxyAPIAttributionResolver.load(home: root, fileManager: fileManager)
        for model in ["gpt-5.5", "proxy-codex-alias"] {
            let attribution = resolver.attribution(
                model: model,
                modelProvider: .unknown,
                sessionID: nil,
                timestampUnixMs: nil,
                tokens: Self.tokens)

            #expect(attribution.route == .unknown)
            #expect(attribution.modelProvider == .unknown)
            #expect(attribution.upstream == nil)
            #expect(!attribution.evidence.contains(.cliProxyAuthInventory))
            #expect(!attribution.evidence.contains(.cliProxyModelAlias))
            #expect(!attribution.evidence.contains(.cliProxyRequestLog))
        }
    }

    @Test
    func `codex oauth model and alias resolve after request route evidence`() {
        let timestamp = Date(timeIntervalSince1970: 1_784_179_200)
        for model in ["gpt-5.5", "proxy-codex-alias"] {
            let resolver = CLIProxyAPIAttributionResolver(
                observations: [
                    .init(sessionID: "proxied-session", model: model, timestamp: timestamp),
                ],
                authProviders: [
                    .init(provider: "codex", authType: .oauth),
                ],
                codexOAuthModelAliases: ["proxy-codex-alias": "gpt-5.5"])
            let attribution = resolver.attribution(
                model: model,
                modelProvider: .unknown,
                sessionID: "proxied-session",
                timestampUnixMs: Int64(timestamp.timeIntervalSince1970 * 1000),
                tokens: Self.tokens)

            #expect(attribution.route == .cliProxyAPI)
            #expect(attribution.modelProvider == .openAI)
            #expect(attribution.upstream == .init(provider: "codex", authType: .oauth, model: "gpt-5.5"))
            #expect(attribution.evidence.contains(.cliProxyAuthInventory))
            #expect(attribution.evidence.contains(.cliProxyModelAlias))
            #expect(attribution.evidence.contains(.cliProxyRequestLog))
        }
    }

    @Test
    func `codex oauth alias parser ignores comments and other providers`() {
        let configuration = """
        # oauth-model-alias:
        #   codex:
        #     - name: "ignored"
        oauth-model-alias:
          codex:
            - name: 'gpt-5.5'
              alias: 'proxy-codex-alias' # local alias
          vertex:
            - name: "gemini-test"
              alias: "unrelated-alias"
        """

        #expect(CLIProxyAPIAttributionResolver.parseCodexOAuthModelAliases(configuration) == [
            "proxy-codex-alias": "gpt-5.5",
        ])
    }

    @Test
    func `weaker live route evidence preserves cached telemetry upstream`() {
        let cached = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            upstream: .init(provider: "codex", authType: .oauth, model: "gpt-5.5"),
            evidence: [.cliProxyRequestLog, .cliProxyUsageTelemetry, .modelProvider])
        let live = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            evidence: [.cliProxyRequestLog, .modelProvider])

        #expect(CostUsageScanner.preferredCLIProxyAPIAttribution(live: live, cached: cached) == cached)
    }

    @Test
    func `ambiguous live batch match preserves durable cached telemetry`() {
        let telemetry = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            upstream: .init(provider: "codex", authType: .oauth, model: "gpt-5.5"),
            evidence: [.cliProxyRequestLog, .cliProxyUsageTelemetry, .modelProvider])
        let requestLogOnly = CostUsageAttribution(
            client: .claudeCode,
            route: .cliProxyAPI,
            modelProvider: .openAI,
            evidence: [.cliProxyRequestLog, .modelProvider])

        #expect(CostUsageScanner.shouldPreserveCachedCLIProxyAPIAttribution(
            telemetry,
            allowCached: true,
            hasMatchingObservation: true))
        #expect(!CostUsageScanner.shouldPreserveCachedCLIProxyAPIAttribution(
            requestLogOnly,
            allowCached: true,
            hasMatchingObservation: true))
        #expect(CostUsageScanner.shouldPreserveCachedCLIProxyAPIAttribution(
            requestLogOnly,
            allowCached: true,
            hasMatchingObservation: false))
        #expect(!CostUsageScanner.shouldPreserveCachedCLIProxyAPIAttribution(
            telemetry,
            allowCached: false,
            hasMatchingObservation: false))
    }

    @Test
    func `codex oauth alias keeps direct historical usage with Claude`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        _ = try env.writeClaudeProjectFile(
            relativePath: "aliased-proxy/session.jsonl",
            contents: env.jsonl((0..<1).map { index in
                [
                    "type": "assistant",
                    "timestamp": env.isoString(for: day.addingTimeInterval(TimeInterval(index))),
                    "sessionId": "aliased-proxy-session",
                    "requestId": "aliased-request-\(index)",
                    "message": [
                        "id": "aliased-message-\(index)",
                        "model": "proxy-codex-alias",
                        "usage": ["input_tokens": 100, "output_tokens": 5],
                    ],
                ]
            }))
        let cliProxyHome = env.root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        try FileManager.default.createDirectory(at: cliProxyHome, withIntermediateDirectories: true)
        try Self.writeCodexAliasConfiguration(to: cliProxyHome, fileManager: .default)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            cliProxyAPIHome: cliProxyHome)

        let codex = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        let claude = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)

        #expect(codex.daily.isEmpty)
        #expect(claude.daily.first?.totalTokens == 105)
        #expect(claude.daily.first?.modelBreakdowns?.count == 1)
        #expect(claude.daily.first?.modelBreakdowns?.allSatisfy {
            $0.attribution?.route != .cliProxyAPI
        } == true)
    }

    private static let tokens = CLIProxyAPIAttributionResolver.TokenSignature(
        input: 10,
        cacheRead: 30,
        cacheCreate: 40,
        output: 20)

    private static func writeCodexAliasConfiguration(
        to root: URL,
        fileManager: FileManager) throws
    {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = """
        oauth-model-alias:
          codex:
            - name: "gpt-5.5"
              alias: "proxy-codex-alias"
              force-mapping: true
          vertex:
            - name: "gemini-test"
              alias: "unrelated-alias"
        """
        try Data(configuration.utf8).write(to: root.appendingPathComponent("config.yaml"))
        try Data(#"{"type":"codex","disabled":false}"#.utf8)
            .write(to: root.appendingPathComponent("codex-auth.json"))
    }
}
