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
