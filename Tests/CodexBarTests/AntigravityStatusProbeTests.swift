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
        #expect(primary.remainingPercent.rounded() == 50)
        #expect(usage.secondary?.remainingPercent.rounded() == 80)
        #expect(usage.tertiary?.remainingPercent.rounded() == 20)
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
    func `claude bar can use thinking variants`() throws {
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
        #expect(usage.primary?.remainingPercent.rounded() == 30)
    }

    @Test
    func `claude bar uses thinking model when it is the only claude option`() throws {
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
        #expect(usage.primary?.remainingPercent.rounded() == 70)
        #expect(usage.secondary?.remainingPercent.rounded() == 40)
    }

    @Test
    func `gemini pro bar unavailable when only excluded variants exist`() throws {
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
        #expect(usage.secondary == nil)
        #expect(usage.primary?.remainingPercent.rounded() == 30)
    }

    @Test
    func `gemini pro chooses pro low model`() throws {
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
        #expect(usage.secondary?.remainingPercent.rounded() == 40)
    }

    @Test
    func `gemini pro low wins over standard pro when both exist`() throws {
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
        #expect(usage.secondary?.remainingPercent.rounded() == 90)
    }

    @Test
    func `gemini pro prefers model with remaining data over low priority placeholder`() throws {
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
        #expect(usage.secondary?.remainingPercent.rounded() == 100)
    }

    @Test
    func `gemini flash does not fallback to lite variant`() throws {
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
        #expect(usage.primary?.remainingPercent.rounded() == 30)
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
        #expect(usage.primary?.remainingPercent.rounded() == 30)
        #expect(usage.secondary?.remainingPercent.rounded() == 40)
        #expect(usage.tertiary?.remainingPercent.rounded() == 100)
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
        #expect(usage.secondary?.remainingPercent.rounded() == 100)
        #expect(usage.tertiary?.remainingPercent.rounded() == 100)
        #expect(usage.identity?.accountEmail == "user@example.com")
    }
}

extension AntigravityStatusProbeTests {
    @Test
    func `extra rate windows preserve all model quotas in stable family order`() throws {
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
        let extraWindows = try #require(usage.extraRateWindows)

        // Local source shows all models. Order: Claude → Gemini Pro (High before Low) → GPT-OSS (unknown, last)
        #expect(extraWindows.map(\.id) == [
            "MODEL_PLACEHOLDER_M50",
            "MODEL_PLACEHOLDER_M52",
            "MODEL_PLACEHOLDER_M53",
            "MODEL_PLACEHOLDER_M55",
        ])
        #expect(extraWindows.map(\.title) == [
            "Claude Opus 4.6 (Thinking)",
            "Gemini 3 Pro (High)",
            "Gemini 3 Pro (Low)",
            "GPT-OSS 120B (Medium)",
        ])
        #expect(extraWindows.map { $0.window.remainingPercent.rounded() } == [75, 100, 50, 25])
        #expect(extraWindows.last?.window.resetDescription == "tomorrow")
    }

    @Test
    func `model without remaining fraction keeps reset time`() throws {
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
        #expect(usage.secondary?.remainingPercent.rounded() == 0)
        #expect(usage.secondary?.resetsAt == resetTime)
        #expect(usage.tertiary?.remainingPercent.rounded() == 100)
    }

    @Test
    func `filtered variants fall back to a visible primary snapshot`() throws {
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
            accountPlan: "Pro")

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.primary?.remainingPercent.rounded() == 20)
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
        #expect(usage.accountEmail(for: .antigravity) == "test@example.com")
        #expect(usage.loginMethod(for: .antigravity) == "Pro")
    }

    // MARK: - Source-aware filter + sort tests

    @Test
    func `local source shows all models including gpt oss at full remaining fraction`() throws {
        // Fixture A: 8 opaque-ID models, source .local → all shown (show-all path)
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
                // GPT-OSS pinned at remainingFraction == 1.0 — shown by local show-all
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
        let extraWindows = try #require(usage.extraRateWindows)
        let ids = extraWindows.map(\.id)

        // All 8 models present
        #expect(ids.count == 8)
        // GPT-OSS shown despite remainingFraction == 1.0 (local show-all regression guard)
        #expect(ids.contains("MODEL_PLACEHOLDER_M55"))

        // Order: Claude (version 4.6 → both at same version, Opus vs Sonnet by label)
        //        → Gemini Pro 3.1 (High before Low)
        //        → Gemini Flash 3.5 (High, Medium, Low by tier)
        //        → GPT-OSS (unknown bucket, last)
        let titles = extraWindows.map(\.title)
        // Claude family first
        let claudeRange = titles.prefix(2)
        #expect(claudeRange.allSatisfy { $0.lowercased().contains("claude") })
        // Gemini Pro next
        let geminiProRange = titles.dropFirst(2).prefix(2)
        #expect(geminiProRange.allSatisfy { $0.lowercased().contains("gemini") && $0.lowercased().contains("pro") })
        // Gemini Flash next
        let geminiFlashRange = titles.dropFirst(4).prefix(3)
        #expect(geminiFlashRange.allSatisfy { $0.lowercased().contains("gemini") && $0.lowercased().contains("flash") })
        // GPT-OSS last
        #expect(titles.last == "GPT-OSS 120B (Medium)")

        // Within Gemini Pro 3.1: High before Low
        let proTitles = Array(geminiProRange)
        #expect(proTitles[0].contains("High"))
        #expect(proTitles[1].contains("Low"))

        // Within Gemini Flash 3.5: High(0) → Medium(1) → Low(2)
        let flashTitles = Array(geminiFlashRange)
        #expect(flashTitles[0].contains("High"))
        #expect(flashTitles[1].contains("Medium"))
        #expect(flashTitles[2].contains("Low"))
    }

    @Test
    func `remote source filters junk models and keeps family recognized ones`() throws {
        // Fixture B: verified 13 remote models; 6 junk hidden, 7 survivors present
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                // junk: image
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Image",
                    modelId: "gemini-2-5-flash-image",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: tab autocomplete
                AntigravityModelQuota(
                    label: "Tab Flash Lite Vertex",
                    modelId: "tab_flash_lite_vertex",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 2.5 Pro",
                    modelId: "gemini-2-5-pro",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "gemini-3-pro-high",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: lite
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Lite",
                    modelId: "gemini-2-5-flash-lite",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: image
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: lite
                AntigravityModelQuota(
                    label: "Gemini 3.1 Flash Lite",
                    modelId: "gemini-3-1-flash-lite",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (Low)",
                    modelId: "gemini-3-1-pro-low",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3.1 Pro (High)",
                    modelId: "gemini-3-1-pro-high",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // junk: tab autocomplete
                AntigravityModelQuota(
                    label: "Tab Jump Flash Lite Vertex",
                    modelId: "tab_jump_flash_lite_vertex",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "gemini-3-pro-low",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                // survivor
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash",
                    modelId: "gemini-2-5-flash",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extraWindows = try #require(usage.extraRateWindows)
        let ids = extraWindows.map(\.id)

        // 6 junk IDs must be absent
        #expect(!ids.contains("gemini-2-5-flash-image"))
        #expect(!ids.contains("tab_flash_lite_vertex"))
        #expect(!ids.contains("gemini-2-5-flash-lite"))
        #expect(!ids.contains("gemini-3-pro-image"))
        #expect(!ids.contains("gemini-3-1-flash-lite"))
        #expect(!ids.contains("tab_jump_flash_lite_vertex"))

        // 7 survivors must be present by ID
        #expect(ids.contains("gemini-2-5-pro"))
        #expect(ids.contains("gemini-3-pro-high"))
        #expect(ids.contains("gemini-3-flash"))
        #expect(ids.contains("gemini-3-1-pro-low"))
        #expect(ids.contains("gemini-3-1-pro-high"))
        #expect(ids.contains("gemini-3-pro-low"))
        #expect(ids.contains("gemini-2-5-flash"))

        // Version-descending within Gemini Pro: 3.1 before 3 before 2.5
        let proIds = ids.filter { $0.contains("pro") && !$0.contains("image") }
        let proIndexOf: (String) -> Int = { id in proIds.firstIndex(of: id) ?? Int.max }
        #expect(proIndexOf("gemini-3-1-pro-high") < proIndexOf("gemini-3-pro-high"))
        #expect(proIndexOf("gemini-3-pro-high") < proIndexOf("gemini-2-5-pro"))

        // Within same version, High before Low
        #expect(proIndexOf("gemini-3-1-pro-high") < proIndexOf("gemini-3-1-pro-low"))
        #expect(proIndexOf("gemini-3-pro-high") < proIndexOf("gemini-3-pro-low"))
    }

    @Test
    func `remote source shows consumed junk models despite filter`() throws {
        // Fixture C: junk models with remainingFraction < 0.999 must be shown
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                // consumed tab — should be shown
                AntigravityModelQuota(
                    label: "Tab Flash Lite Vertex",
                    modelId: "tab_flash_lite_vertex",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
                // consumed image — should be shown
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 0.4,
                    resetTime: nil,
                    resetDescription: nil),
                // unconsumed sibling tab (0.9995 >= 0.999) — should be hidden
                AntigravityModelQuota(
                    label: "Tab Jump Flash Lite Vertex",
                    modelId: "tab_jump_flash_lite_vertex",
                    remainingFraction: 0.9995,
                    resetTime: nil,
                    resetDescription: nil),
                // a clean survivor for non-empty guard
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let extraWindows = try #require(usage.extraRateWindows)
        let ids = extraWindows.map(\.id)

        // Consumed junk models shown despite being junk type
        #expect(ids.contains("tab_flash_lite_vertex"))
        #expect(ids.contains("gemini-3-pro-image"))

        // Unconsumed sibling stays hidden
        #expect(!ids.contains("tab_jump_flash_lite_vertex"))
    }

    @Test
    func `remote source image models do not drive family summary bars`() throws {
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 0.2,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "gemini-3-pro-high",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash Image",
                    modelId: "gemini-3-flash-image",
                    remainingFraction: 0.1,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Flash",
                    modelId: "gemini-3-flash",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.secondary?.usedPercent == 10)
        #expect(usage.tertiary?.usedPercent == 20)
        #expect(usage.extraRateWindows?.map(\.id).contains("gemini-3-pro-image") == true)
        #expect(usage.extraRateWindows?.map(\.id).contains("gemini-3-flash-image") == true)
    }

    @Test
    func `remote source yields nil extra windows when all models are unconsumed junk`() throws {
        // Fixture D: all-junk-unconsumed → extraRateWindows nil
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Tab Flash Lite Vertex",
                    modelId: "tab_flash_lite_vertex",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 2.5 Flash Lite",
                    modelId: "gemini-2-5-flash-lite",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro Image",
                    modelId: "gemini-3-pro-image",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Unknown Model X",
                    modelId: "unknown-model-x",
                    remainingFraction: 1.0,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `ordering edge cases with unparseable version and equal version differing tier`() throws {
        // Fixture F: local source; unparseable-version Gemini Pro lands last in pro group;
        // same-version High precedes Low
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (Low)",
                    modelId: "MODEL_PLACEHOLDER_M70",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini 3 Pro (High)",
                    modelId: "MODEL_PLACEHOLDER_M71",
                    remainingFraction: 0.8,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Gemini Pro Experimental",
                    modelId: "MODEL_PLACEHOLDER_M72",
                    remainingFraction: 0.3,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Claude Sonnet 4",
                    modelId: "MODEL_PLACEHOLDER_M73",
                    remainingFraction: 0.9,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        let extraWindows = try #require(usage.extraRateWindows)
        let titles = extraWindows.map(\.title)

        // Claude first
        #expect(titles[0] == "Claude Sonnet 4")
        // Within Gemini Pro: version-3 models before unparseable-version model
        // High before Low at same version
        let proIndex: (String) -> Int = { t in titles.firstIndex(of: t) ?? Int.max }
        #expect(proIndex("Gemini 3 Pro (High)") < proIndex("Gemini 3 Pro (Low)"))
        #expect(proIndex("Gemini 3 Pro (High)") < proIndex("Gemini Pro Experimental"))
        #expect(proIndex("Gemini 3 Pro (Low)") < proIndex("Gemini Pro Experimental"))
    }

    @Test
    func `nil version unknown family models sort deterministically by label`() throws {
        // Strict-weak-ordering guard: two .unknown models with unparseable versions
        // should sort by label without trapping
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Zebra Unknown Model",
                    modelId: "MODEL_PLACEHOLDER_MA",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "Alpha Unknown Model",
                    modelId: "MODEL_PLACEHOLDER_MB",
                    remainingFraction: 0.5,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)

        let usage = try snapshot.toUsageSnapshot()
        let extraWindows = try #require(usage.extraRateWindows)
        let titles = extraWindows.map(\.title)

        // Deterministic: label tiebreaker → Alpha before Zebra
        #expect(titles == ["Alpha Unknown Model", "Zebra Unknown Model"])
    }

    @Test
    func `hyphenated raw model ids without display name parse minor version`() throws {
        // When the remote catalog omits displayName/label, the raw hyphenated model id
        // becomes the label. The newer 3.1 entry must still sort before the 3.0 entry.
        let snapshot = AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "gemini-3-pro-high",
                    modelId: "gemini-3-pro-high",
                    remainingFraction: 1,
                    resetTime: nil,
                    resetDescription: nil),
                AntigravityModelQuota(
                    label: "gemini-3-1-pro-low",
                    modelId: "gemini-3-1-pro-low",
                    remainingFraction: 1,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .remote)

        let usage = try snapshot.toUsageSnapshot()
        let titles = try #require(usage.extraRateWindows).map(\.title)

        // 3.1 parses from the hyphenated id and sorts newest-first, ahead of 3.0.
        #expect(titles == ["gemini-3-1-pro-low", "gemini-3-pro-high"])
    }

    @Test
    func `http probe errors still count as reachable`() {
        #expect(
            AntigravityStatusProbe.isReachableProbeError(
                AntigravityStatusProbeError.apiError("HTTP 403: Forbidden")))
        #expect(
            AntigravityStatusProbe.isReachableProbeError(
                AntigravityStatusProbeError.apiError("HTTP 404: Not Found")))
        #expect(
            !AntigravityStatusProbe.isReachableProbeError(
                AntigravityStatusProbeError.apiError("Invalid response")))
        #expect(!AntigravityStatusProbe.isReachableProbeError(AntigravityStatusProbeError.notRunning))
    }

    @Test
    func `fallback probe port prefers non extension candidate`() {
        #expect(
            AntigravityStatusProbe.fallbackProbePort(
                ports: [51170, 61775],
                extensionPort: 61775) == 51170)
        #expect(
            AntigravityStatusProbe.fallbackProbePort(
                ports: [61775],
                extensionPort: 61775) == 61775)
        #expect(
            AntigravityStatusProbe.fallbackProbePort(
                ports: [51170, 61775],
                extensionPort: nil) == 51170)
    }
}
