import Foundation
import Testing
@testable import CodexBarCore

private final class AntigravityAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [AntigravityStatusProbe.AntigravityConnectionEndpoint] = []

    func append(_ endpoint: AntigravityStatusProbe.AntigravityConnectionEndpoint) {
        self.lock.lock()
        self.endpoints.append(endpoint)
        self.lock.unlock()
    }

    func snapshot() -> [AntigravityStatusProbe.AntigravityConnectionEndpoint] {
        self.lock.lock()
        let snapshot = self.endpoints
        self.lock.unlock()
        return snapshot
    }
}

struct AntigravityStatusProbeTests {
    @Test
    func `process detection accepts antigravity 2 unsuffixed language server`() {
        let command = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --override_ide_name antigravity --override_ide_version 2.0.0 \
        --csrf_token token --app_data_dir antigravity
        """

        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(command))
    }

    @Test
    func `process detection accepts antigravity language server paths with spaces`() {
        let command = """
        /Applications/Google Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --override_ide_name antigravity --csrf_token token --app_data_dir antigravity
        """

        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(command))
    }

    @Test
    func `process detection accepts hyphenated language server from app bundle`() throws {
        let command = """
        /Applications/Google Antigravity.app/Contents/Resources/bin/language-server --standalone \
        --csrf_token token --extension_server_port 64123
        """

        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(command))

        let result = try AntigravityStatusProbe.processInfo(fromProcessListOutput: "  321 \(command)")
        #expect(result.pid == 321)
        #expect(result.csrfToken == "token")
        #expect(result.extensionPort == 64123)
    }

    @Test
    func `process detection keeps ignoring non language server antigravity helpers`() {
        let helper = """
        /Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper \
        --type=renderer --user-data-dir=/Users/test/Library/Application Support/Antigravity
        """

        #expect(!AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(helper))
    }

    @Test
    func `process detection still accepts legacy antigravity language server`() {
        let command = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server_macos \
        --csrf_token token --app_data_dir antigravity
        """

        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(command))
    }

    @Test
    func `process detection accepts platform suffixed antigravity language server`() throws {
        let output = """
          101 /Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm \
          --csrf_token ide-token --app_data_dir antigravity --extension_server_port 54977
        """

        let result = try AntigravityStatusProbe.processInfo(fromProcessListOutput: output, scope: .appOnly)

        #expect(result.pid == 101)
        #expect(result.csrfToken == "ide-token")
        #expect(result.extensionPort == 54977)
    }

    @Test
    func `process detection accepts antigravity cli without csrf token`() {
        // The CLI launches its language server without a `--csrf_token` flag.
        let node = """
        node /Users/test/.gemini/antigravity-cli/build/mcp-server.cjs \
        --app_data_dir /Users/test/.gemini/antigravity
        """
        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(node))

        let agy = "/Users/test/.local/bin/agy -p hello"
        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(agy))

        let agyUnderscore = "/usr/local/bin/agy --app_data_dir /Users/test/.gemini/antigravity_cli"
        #expect(AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(agyUnderscore))
    }

    @Test
    func `process detection ignores unrelated binaries containing agy substring`() {
        // "agy" must be path-anchored so unrelated commands do not match.
        #expect(!AntigravityStatusProbe.isAntigravityLanguageServerCommandLine("/usr/bin/legacy --run"))
        #expect(!AntigravityStatusProbe.isAntigravityLanguageServerCommandLine("/opt/imagymagic/bin/tool"))
    }

    @Test
    func `process detection ignores cli names outside explicit cli path segments`() {
        #expect(
            !AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(
                "/usr/bin/node /tmp/not-antigravity-cli/build/server.js"))
        #expect(
            !AntigravityStatusProbe.isAntigravityLanguageServerCommandLine(
                "/usr/bin/helper --workspace antigravity-cli"))
    }

    @Test
    func `process kind distinguishes app ide language server and cli`() {
        let app = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server \
        --csrf_token token --app_data_dir antigravity
        """
        let ide = """
        /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm \
        --csrf_token token --app_data_dir antigravity-ide
        """
        #expect(AntigravityStatusProbe.antigravityProcessKind(app) == .app)
        #expect(AntigravityStatusProbe.antigravityProcessKind(ide) == .ide)
        #expect(AntigravityStatusProbe.antigravityProcessKind("/Users/test/.local/bin/agy -p hi") == .cli)
        #expect(
            AntigravityStatusProbe.antigravityProcessKind(
                "node /x/.gemini/antigravity-cli/build/mcp-server.cjs --app_data_dir /x/.gemini/antigravity") == .cli)
        #expect(AntigravityStatusProbe.antigravityProcessKind("/usr/bin/legacy --run") == nil)
    }

    @Test
    func `csrf token stays required for ide but optional for cli`() {
        // Desktop app/IDE with a token returns it.
        let appWithToken = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server \
        --csrf_token ide-token --app_data_dir antigravity
        """
        #expect(AntigravityStatusProbe.resolvedCSRFToken(forKind: .app, command: appWithToken) == "ide-token")

        // Tokenless desktop app is skipped (nil) so detection keeps scanning for a valid
        // server and preserves the missing-token diagnostic - no empty-token probe.
        let appNoToken = """
        /Applications/Antigravity.app/Contents/Resources/bin/language_server \
        --app_data_dir antigravity
        """
        #expect(AntigravityStatusProbe.resolvedCSRFToken(forKind: .app, command: appNoToken) == nil)

        // CLI without a token resolves to an empty token (its server needs none).
        #expect(
            AntigravityStatusProbe.resolvedCSRFToken(
                forKind: .cli, command: "/Users/test/.local/bin/agy -p hi")?.isEmpty == true)

        // A CLI that does carry a token still uses it.
        #expect(
            AntigravityStatusProbe.resolvedCSRFToken(
                forKind: .cli, command: "/Users/test/.local/bin/agy --csrf_token cli-token") == "cli-token")
    }

    @Test
    func `process scan skips tokenless ide before later valid ide`() throws {
        let tokenlessIDE =
            "  100 /Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir antigravity"
        let validIDE = "  101 /Applications/Antigravity.app/Contents/Resources/bin/language_server " +
            "--csrf_token ide-token --app_data_dir antigravity " +
            "--extension_server_port 64432 --extension_server_csrf_token extension-token"
        let output = [tokenlessIDE, validIDE].joined(separator: "\n")

        let result = try AntigravityStatusProbe.processInfo(fromProcessListOutput: output)

        #expect(result.pid == 101)
        #expect(result.csrfToken == "ide-token")
        #expect(result.extensionPort == 64432)
        #expect(result.extensionServerCSRFToken == "extension-token")
    }

    @Test
    func `process scan returns all valid app candidates`() throws {
        let firstApp = "  101 /Applications/Antigravity.app/Contents/Resources/bin/language_server " +
            "--csrf_token first-token --app_data_dir antigravity"
        let secondApp = "  102 /Applications/Antigravity.app/Contents/Resources/bin/language_server " +
            "--csrf_token second-token --app_data_dir antigravity " +
            "--extension_server_port 64432 --extension_server_csrf_token extension-token"
        let output = [firstApp, secondApp].joined(separator: "\n")

        let results = try AntigravityStatusProbe.processInfos(fromProcessListOutput: output, scope: .appOnly)

        #expect(results.map(\.pid) == [101, 102])
        #expect(results.map(\.csrfToken) == ["first-token", "second-token"])
        #expect(results.last?.extensionPort == 64432)
        #expect(results.last?.extensionServerCSRFToken == "extension-token")
    }

    @Test
    func `local snapshot score prefers quota summary over legacy model quotas`() {
        let legacy = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Low",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 0.9,
                    resetTime: Date(timeIntervalSince1970: 1_700_000_000),
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet",
                    modelId: "claude-sonnet",
                    remainingFraction: 0.5,
                    resetTime: Date(timeIntervalSince1970: 1_700_000_000),
                    resetDescription: nil),
            ],
            accountEmail: "user@example.com",
            accountPlan: "Pro",
            source: .local)
        let summary = AntigravityStatusSnapshot(
            quotaSummary: AntigravityQuotaSummary(
                description: nil,
                groups: [
                    AntigravityQuotaSummaryGroup(
                        displayName: "Gemini Models",
                        description: nil,
                        buckets: [
                            AntigravityQuotaSummaryBucket(
                                bucketId: "gemini-5h",
                                displayName: "Five Hour Limit",
                                remainingFraction: 0.9,
                                resetDescription: nil,
                                disabled: false),
                            AntigravityQuotaSummaryBucket(
                                bucketId: "gemini-weekly",
                                displayName: "Weekly Limit",
                                remainingFraction: 0.8,
                                resetDescription: nil,
                                disabled: false),
                        ]),
                    AntigravityQuotaSummaryGroup(
                        displayName: "Claude and GPT models",
                        description: nil,
                        buckets: [
                            AntigravityQuotaSummaryBucket(
                                bucketId: "3p-5h",
                                displayName: "Five Hour Limit",
                                remainingFraction: 0.7,
                                resetDescription: nil,
                                disabled: false),
                            AntigravityQuotaSummaryBucket(
                                bucketId: "3p-weekly",
                                displayName: "Weekly Limit",
                                remainingFraction: 0.6,
                                resetDescription: nil,
                                disabled: false),
                        ]),
                ]),
            accountEmail: "user@example.com",
            accountPlan: "Pro",
            source: .local)

        #expect(AntigravityStatusProbe.localSnapshotScore(summary) > AntigravityStatusProbe.localSnapshotScore(legacy))
    }

    @Test
    func `process scan reports missing csrf when only tokenless ide matches`() {
        let output = """
          100 /Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir antigravity
        """

        #expect(throws: AntigravityStatusProbeError.missingCSRFToken) {
            try AntigravityStatusProbe.processInfo(fromProcessListOutput: output)
        }
    }

    @Test
    func `process scan allows empty csrf only for explicit cli match`() throws {
        let output = """
          200 /Users/test/.local/bin/agy -p hello
        """

        let result = try AntigravityStatusProbe.processInfo(fromProcessListOutput: output)

        #expect(result.pid == 200)
        #expect(result.csrfToken.isEmpty)
        #expect(result.commandLine == "/Users/test/.local/bin/agy -p hello")
    }

    @Test
    func `ideOnly scope skips app and cli processes and reports not running`() {
        let output = "  200 /Users/test/.local/bin/agy -p hello"

        #expect(throws: AntigravityStatusProbeError.notRunning) {
            try AntigravityStatusProbe.processInfo(fromProcessListOutput: output, scope: .ideOnly)
        }

        let app = "  101 /Applications/Antigravity.app/Contents/Resources/bin/language_server " +
            "--csrf_token app-token --app_data_dir antigravity"
        #expect(throws: AntigravityStatusProbeError.notRunning) {
            try AntigravityStatusProbe.processInfo(fromProcessListOutput: app, scope: .ideOnly)
        }
    }

    @Test
    func `ideOnly scope still matches ide server listed after cli and app processes`() throws {
        let cli = "  200 /Users/test/.local/bin/agy -p hello"
        let app = "  101 /Applications/Antigravity.app/Contents/Resources/bin/language_server " +
            "--csrf_token app-token --app_data_dir antigravity"
        let ide = "  102 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/" +
            "language_server_macos_arm " +
            "--csrf_token ide-token --app_data_dir antigravity"
        let output = cli + "\n" + app + "\n" + ide

        let result = try AntigravityStatusProbe.processInfo(fromProcessListOutput: output, scope: .ideOnly)

        #expect(result.pid == 102)
        #expect(result.csrfToken == "ide-token")
    }

    @Test
    func `appOnly scope skips ide and cli processes`() throws {
        let cli = "  200 /Users/test/.local/bin/agy -p hello"
        let ide = "  102 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/" +
            "language_server_macos_arm --csrf_token ide-token --app_data_dir antigravity-ide"
        let app = "  101 /Applications/Antigravity.app/Contents/Resources/bin/language_server " +
            "--csrf_token app-token --app_data_dir antigravity"
        let output = cli + "\n" + ide + "\n" + app

        let result = try AntigravityStatusProbe.processInfo(fromProcessListOutput: output, scope: .appOnly)

        #expect(result.pid == 101)
        #expect(result.csrfToken == "app-token")
    }
}

extension AntigravityStatusProbeTests {
    @Test
    func `localhost trust policy only accepts local server trust challenges`() {
        #expect(
            LocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true))
        #expect(
            LocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "LOCALHOST",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true))

        #expect(
            !LocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "cursor.com",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true))
        #expect(
            !LocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                hasServerTrust: true))
        #expect(
            !LocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "127.0.0.1",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: false))
    }

    @Test
    func `localhost trust policy rejects non loopback hostnames that contain localhost`() {
        #expect(
            !LocalhostTrustPolicy.shouldAcceptServerTrust(
                host: "localhost.example.com",
                authenticationMethod: NSURLAuthenticationMethodServerTrust,
                hasServerTrust: true))
    }

    @Test
    func `connection candidates preserve scheme order and endpoint tokens`() {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: "extension-token")

        #expect(
            candidates == [
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64440,
                    csrfToken: "language-token",
                    source: .languageServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "extension-token",
                    source: .extensionServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
            ])
    }

    @Test
    func `connection candidates restrict plain http probing to the declared extension port`() {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64440, 64441],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: nil)

        #expect(
            candidates == [
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64440,
                    csrfToken: "language-token",
                    source: .languageServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64441,
                    csrfToken: "language-token",
                    source: .languageServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
            ])
    }

    @Test
    func `connection candidates preserve extension fallback when extension token is unavailable`() {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: nil)

        #expect(
            candidates == [
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64440,
                    csrfToken: "language-token",
                    source: .languageServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
            ])
    }

    @Test
    func `connection candidates do not duplicate the same http target when ports overlap`() {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64432],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: nil)

        #expect(
            candidates == [
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .languageServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
            ])
    }

    @Test
    func `request endpoints retry extension server after language server success`() {
        let resolvedEndpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "language-token",
            source: .languageServer)

        let endpoints = AntigravityStatusProbe.requestEndpoints(
            resolvedEndpoint: resolvedEndpoint,
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: "extension-token")

        #expect(
            endpoints == [
                resolvedEndpoint,
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "extension-token",
                    source: .extensionServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
            ])
    }

    @Test
    func `request endpoints preserve extension fallback when extension token is unavailable`() {
        let resolvedEndpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "language-token",
            source: .languageServer)

        let endpoints = AntigravityStatusProbe.requestEndpoints(
            resolvedEndpoint: resolvedEndpoint,
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: nil)

        #expect(
            endpoints == [
                resolvedEndpoint,
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
            ])
    }

    @Test
    func `request endpoints retry alternate token after extension server wins discovery`() {
        let resolvedEndpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "http",
            port: 64432,
            csrfToken: "extension-token",
            source: .extensionServer)

        let endpoints = AntigravityStatusProbe.requestEndpoints(
            resolvedEndpoint: resolvedEndpoint,
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: "extension-token")

        #expect(
            endpoints == [
                resolvedEndpoint,
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "http",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .extensionServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64440,
                    csrfToken: "language-token",
                    source: .languageServer),
            ])
    }

    @Test
    func `request endpoints keep https language server fallback after extension probe wins`() {
        let resolvedEndpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "http",
            port: 64432,
            csrfToken: "language-token",
            source: .extensionServer)

        let endpoints = AntigravityStatusProbe.requestEndpoints(
            resolvedEndpoint: resolvedEndpoint,
            listeningPorts: [64432, 64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: nil)

        #expect(
            endpoints == [
                resolvedEndpoint,
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64432,
                    csrfToken: "language-token",
                    source: .languageServer),
                AntigravityStatusProbe.AntigravityConnectionEndpoint(
                    scheme: "https",
                    port: 64440,
                    csrfToken: "language-token",
                    source: .languageServer),
            ])
    }

    @Test
    func `parsed request retries later endpoints after api level error payload`() async throws {
        let endpoints = [
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "https",
                port: 64440,
                csrfToken: "bad-token",
                source: .languageServer),
            AntigravityStatusProbe.AntigravityConnectionEndpoint(
                scheme: "http",
                port: 64432,
                csrfToken: "good-token",
                source: .extensionServer),
        ]
        let attempted = AntigravityAttemptRecorder()

        let snapshot = try await AntigravityStatusProbe.makeParsedRequest(
            payload: AntigravityStatusProbe.RequestPayload(
                path: "/exa.language_server_pb.LanguageServerService/GetUserStatus",
                body: ["metadata": [:]]),
            context: AntigravityStatusProbe.RequestContext(
                endpoints: endpoints,
                timeout: 1),
            send: { _, endpoint, _ in
                attempted.append(endpoint)
                if endpoint.csrfToken == "bad-token" {
                    return Data(#"{"code":16}"#.utf8)
                }
                return Data(
                    #"""
                    {
                      "code": 0,
                      "userStatus": {
                        "email": "test@example.com",
                        "cascadeModelConfigData": {
                          "clientModelConfigs": []
                        }
                      }
                    }
                    """#.utf8)
            },
            parse: AntigravityStatusProbe.parseUserStatusResponse)

        #expect(snapshot.accountEmail == "test@example.com")
        #expect(attempted.snapshot() == endpoints)
    }

    @Test
    func `endpoint resolver prefers successful https language server candidate`() async throws {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: "extension-token")
        let attempted = AntigravityAttemptRecorder()

        let endpoint = try await AntigravityStatusProbe.resolveWorkingEndpoint(
            candidateEndpoints: candidates,
            timeout: 1)
        { endpoint, _ in
            attempted.append(endpoint)
            return endpoint.scheme == "https" && endpoint.port == 64440
        }

        #expect(endpoint == candidates[0])
        #expect(attempted.snapshot() == [candidates[0]])
    }

    @Test
    func `endpoint resolver falls back to extension server after https language server candidates`() async throws {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64440, 64441],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: "extension-token")
        let attempted = AntigravityAttemptRecorder()

        let endpoint = try await AntigravityStatusProbe.resolveWorkingEndpoint(
            candidateEndpoints: candidates,
            timeout: 1)
        { endpoint, _ in
            attempted.append(endpoint)
            return endpoint.scheme == "http" && endpoint.port == 64432 && endpoint.source == .extensionServer
        }

        #expect(endpoint == candidates[2])
        #expect(attempted.snapshot() == Array(candidates.prefix(3)))
    }

    @Test
    func `endpoint resolver falls back to alternate extension token after primary token fails`() async throws {
        let candidates = AntigravityStatusProbe.connectionCandidates(
            listeningPorts: [64440],
            languageServerCSRFToken: "language-token",
            extensionServerPort: 64432,
            extensionServerCSRFToken: "extension-token")
        let attempted = AntigravityAttemptRecorder()

        let endpoint = try await AntigravityStatusProbe.resolveWorkingEndpoint(
            candidateEndpoints: candidates,
            timeout: 1)
        { endpoint, _ in
            attempted.append(endpoint)
            return endpoint.source == .extensionServer && endpoint.csrfToken == "language-token"
        }

        #expect(endpoint == candidates[2])
        #expect(attempted.snapshot() == candidates)
        #expect(endpoint.csrfToken == "language-token")
    }

    @Test
    func `parses user status response`() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "test@example.com",
            "planStatus": {
              "planInfo": {
                "planName": "Pro"
              }
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Claude 3.5 Sonnet",
                  "modelOrAlias": { "model": "claude-3-5-sonnet" },
                  "quotaInfo": { "remainingFraction": 0.5, "resetTime": "2025-12-24T10:00:00Z" }
                },
                {
                  "label": "Gemini Pro Low",
                  "modelOrAlias": { "model": "gemini-pro-low" },
                  "quotaInfo": { "remainingFraction": 0.8, "resetTime": "2025-12-24T11:00:00Z" }
                },
                {
                  "label": "Gemini Flash",
                  "modelOrAlias": { "model": "gemini-flash" },
                  "quotaInfo": { "remainingFraction": 0.2, "resetTime": "2025-12-24T12:00:00Z" }
                }
              ]
            }
          }
        }
        """

        let data = Data(json.utf8)
        let snapshot = try AntigravityStatusProbe.parseUserStatusResponse(data)
        #expect(snapshot.accountEmail == "test@example.com")
        #expect(snapshot.accountPlan == "Pro")
        #expect(snapshot.modelQuotas.count == 3)

        let usage = try snapshot.toUsageSnapshot()
        guard let primary = usage.primary else {
            return
        }
        #expect(primary.remainingPercent.rounded() == 20)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)

        let extra = try #require(usage.extraRateWindows)
        let claudeWindow = try #require(extra.first(where: { $0.id == "claude-3-5-sonnet" }))
        #expect(claudeWindow.window.remainingPercent.rounded() == 50)
        #expect(claudeWindow.title == "Claude 3.5 Sonnet")
    }

    @Test
    func `prefers user tier name over generic plan info`() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "ultra@example.com",
            "userTier": {
              "id": "google_ai_ultra",
              "name": "Google AI Ultra",
              "description": "Ultra tier"
            },
            "planStatus": {
              "planInfo": {
                "planName": "Pro"
              }
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": []
            }
          }
        }
        """

        let data = Data(json.utf8)
        let snapshot = try AntigravityStatusProbe.parseUserStatusResponse(data)

        #expect(snapshot.accountEmail == "ultra@example.com")
        #expect(snapshot.accountPlan == "Google AI Ultra")
        #expect(snapshot.modelQuotas.isEmpty)
    }

    @Test
    func `falls back to plan info when user tier name is blank`() throws {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "fallback@example.com",
            "userTier": {
              "id": "google_ai_ultra",
              "name": "   ",
              "description": "Ultra tier"
            },
            "planStatus": {
              "planInfo": {
                "planName": "Pro"
              }
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": []
            }
          }
        }
        """

        let data = Data(json.utf8)
        let snapshot = try AntigravityStatusProbe.parseUserStatusResponse(data)

        #expect(snapshot.accountEmail == "fallback@example.com")
        #expect(snapshot.accountPlan == "Pro")
        #expect(snapshot.modelQuotas.isEmpty)
    }

    @Test
    func `claude gpt pool can use thinking variants`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Thinking",
                    modelId: "claude-thinking",
                    remainingFraction: 0.7,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4",
                    modelId: "claude-sonnet-4",
                    remainingFraction: 0.3,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let sonnetWindow = try #require(extra.first(where: { $0.id == "claude-sonnet-4" }))
        #expect(sonnetWindow.window.remainingPercent.rounded() == 30)
    }

    @Test
    func `claude gpt pool uses thinking model when it is the only claude option`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Thinking",
                    modelId: "claude-thinking",
                    remainingFraction: 0.7,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Low",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 40)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let thinkingWindow = try #require(extra.first(where: { $0.id == "claude-thinking" }))
        #expect(thinkingWindow.window.remainingPercent.rounded() == 70)
    }

    @Test
    func `gemini pool unavailable when only excluded variants exist`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini Pro Lite",
                    modelId: "gemini-3-pro-lite",
                    remainingFraction: 0.6,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4",
                    modelId: "claude-sonnet-4",
                    remainingFraction: 0.3,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let claudeWindow = try #require(extra.first(where: { $0.id == "claude-sonnet-4" }))
        #expect(claudeWindow.window.remainingPercent.rounded() == 30)
    }

    @Test
    func `gemini pool chooses most constrained pro variant`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro",
                    modelId: "gemini-3-pro",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Low",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 40)
        #expect(usage.secondary == nil)
    }

    @Test
    func `gemini pool chooses standard pro when it is more constrained than low variant`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro",
                    modelId: "gemini-3-pro",
                    remainingFraction: 0.1,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Low",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 10)
        #expect(usage.secondary == nil)
    }

    @Test
    func `gemini pool ignores reset only placeholder when remaining data exists`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M36",
                    remainingFraction: nil,
                    resetTime: Date(timeIntervalSince1970: 1_735_000_000),
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M37",
                    remainingFraction: 1,
                    resetTime: Date(timeIntervalSince1970: 1_735_100_000),
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 100)
        #expect(usage.secondary == nil)
    }

    @Test
    func `gemini pool does not fallback to lite flash variant`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 2 Flash Lite",
                    modelId: "gemini-2-flash-lite",
                    remainingFraction: 0.2,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4",
                    modelId: "claude-sonnet-4",
                    remainingFraction: 0.3,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.tertiary == nil)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let claudeWindow = try #require(extra.first(where: { $0.id == "claude-sonnet-4" }))
        #expect(claudeWindow.window.remainingPercent.rounded() == 30)
    }

    @Test
    func `falls back to labels when model ids are placeholders`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6",
                    modelId: "MODEL_PLACEHOLDER_M35",
                    remainingFraction: 0.3,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M36",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "MODEL_PLACEHOLDER_M47",
                    remainingFraction: 1,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 40)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)

        let extra = try #require(usage.extraRateWindows)
        let claudeWindow = try #require(extra.first(where: { $0.id == "MODEL_PLACEHOLDER_M35" }))
        #expect(claudeWindow.window.remainingPercent.rounded() == 30)
    }

    @Test
    func `matches remote antigravity model names with parentheses`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Opus 4.6 (Thinking)",
                    modelId: "MODEL_PLACEHOLDER_M50",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6 (Thinking)",
                    modelId: "MODEL_PLACEHOLDER_M51",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M52",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M53",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "MODEL_PLACEHOLDER_M54",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "GPT-OSS 120B (Medium)",
                    modelId: "MODEL_PLACEHOLDER_M55",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: "user@example.com",
            accountPlan: "Pro")

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 100)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.identity?.accountEmail == "user@example.com")
        #expect(usage.extraRateWindows == nil)
    }
}

extension AntigravityStatusProbeTests {
    @Test
    func `known model quota rows collapse into two usage pools`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "GPT-OSS 120B (Medium)",
                    modelId: "MODEL_PLACEHOLDER_M55",
                    remainingFraction: 0.25,
                    resetTime: resetTime,
                    resetDescription: "tomorrow"),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M53",
                    remainingFraction: 0.5,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Opus 4.6 (Thinking)",
                    modelId: "MODEL_PLACEHOLDER_M50",
                    remainingFraction: 0.75,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M52",
                    remainingFraction: 1,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 50)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let gptWindow = try #require(extra.first(where: { $0.id == "MODEL_PLACEHOLDER_M55" }))
        #expect(gptWindow.window.remainingPercent.rounded() == 25)
        let claudeWindow = try #require(extra.first(where: { $0.id == "MODEL_PLACEHOLDER_M50" }))
        #expect(claudeWindow.window.remainingPercent.rounded() == 75)
    }

    @Test
    func `model without remaining fraction stays out of family summary and preserves reset metadata`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_735_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M36",
                    remainingFraction: nil,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "MODEL_PLACEHOLDER_M47",
                    remainingFraction: 1,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 100)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `group without remaining fraction preserves reset metadata as unavailable grouped window`() throws {
        let resetTime = Date(timeIntervalSince1970: 1_735_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M36",
                    remainingFraction: nil,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        let modelWindow = try #require(usage.extraRateWindows?.first)
        #expect(modelWindow.id == "antigravity-gemini")
        #expect(modelWindow.title == "Gemini Models")
        #expect(modelWindow.window.resetsAt == resetTime)
        #expect(modelWindow.usageKnown == false)
    }

    @Test
    func `named rate windows default legacy payloads to known usage`() throws {
        let json = """
        {
          "id": "legacy-window",
          "title": "Legacy Window",
          "window": {
            "usedPercent": 42,
            "windowMinutes": null,
            "resetsAt": null,
            "resetDescription": null,
            "nextRegenPercent": null
          }
        }
        """

        let decoded = try JSONDecoder().decode(NamedRateWindow.self, from: Data(json.utf8))

        #expect(decoded.usageKnown)
    }

    @Test
    func `filtered variants stay out of summary but remain distinct extras`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Lite",
                    modelId: "gemini-3-pro-lite",
                    remainingFraction: 0.6,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash Lite",
                    modelId: "gemini-3-flash-lite",
                    remainingFraction: 0.2,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Tab Autocomplete",
                    modelId: "tab_autocomplete_model",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: "test@example.com",
            accountPlan: "Pro",
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.extraRateWindows?.map(\.id) == [
            "gemini-3-pro-lite",
            "gemini-3-flash-lite",
            "tab_autocomplete_model",
        ])
        #expect(usage.accountEmail(for: .antigravity) == "test@example.com")
        #expect(usage.loginMethod(for: .antigravity) == "Pro")
    }

    // MARK: - Source-aware filter + sort tests

    @Test
    func `local source collapses opaque model ids into two usage pools`() throws {
        // Fixture A: 8 opaque-ID models, source .local -> two grouped quota pools
        let resetTime = Date(timeIntervalSince1970: 1_775_000_000)
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Claude Sonnet 4.6 (Thinking)",
                    modelId: "MODEL_PLACEHOLDER_M60",
                    remainingFraction: 0.8,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Opus 4.6 (Thinking)",
                    modelId: "MODEL_PLACEHOLDER_M61",
                    remainingFraction: 0.7,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M62",
                    remainingFraction: 0.9,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M63",
                    remainingFraction: 0.4,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.5 Flash (High)",
                    modelId: "MODEL_PLACEHOLDER_M64",
                    remainingFraction: 0.6,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.5 Flash (Low)",
                    modelId: "MODEL_PLACEHOLDER_M65",
                    remainingFraction: 0.3,
                    resetTime: resetTime,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3.5 Flash (Medium)",
                    modelId: "MODEL_PLACEHOLDER_M66",
                    remainingFraction: 0.5,
                    resetTime: resetTime,
                    resetDescription: nil),
                // GPT-OSS pinned at remainingFraction == 1.0 - shown by local show-all
                AntigravityModelQuota(
                    label: "GPT-OSS 120B (Medium)",
                    modelId: "MODEL_PLACEHOLDER_M55",
                    remainingFraction: 1.0,
                    resetTime: resetTime,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 30)
        #expect(usage.secondary == nil)

        let extra = try #require(usage.extraRateWindows)
        let opusWindow = try #require(extra.first(where: { $0.id == "MODEL_PLACEHOLDER_M61" }))
        #expect(opusWindow.window.remainingPercent.rounded() == 70)
        let sonnetWindow = try #require(extra.first(where: { $0.id == "MODEL_PLACEHOLDER_M60" }))
        #expect(sonnetWindow.window.remainingPercent.rounded() == 80)
    }
}
