import Foundation
import Testing
@testable import CodexBarCore

private final class AntigravityQuotaSummaryPathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        self.lock.lock()
        self.paths.append(path)
        self.lock.unlock()
    }

    func snapshot() -> [String] {
        self.lock.lock()
        let snapshot = self.paths
        self.lock.unlock()
        return snapshot
    }
}

struct AntigravityQuotaSummaryTests {
    @Test
    func `parses quota summary response into two model groups with session before weekly windows`() throws {
        let snapshot = try AntigravityStatusProbe.parseQuotaSummaryResponse(
            Data(antigravityQuotaSummaryJSON().utf8))

        #expect(snapshot.modelQuotas.isEmpty)
        let usage = try snapshot.toUsageSnapshot()
        let windows = try #require(usage.extraRateWindows)

        #expect(windows.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-gemini-weekly",
            "antigravity-quota-summary-3p-5h",
            "antigravity-quota-summary-3p-weekly",
        ])
        #expect(windows.map(\.title) == [
            "Gemini 5-hour",
            "Gemini weekly",
            "Claude/GPT 5-hour",
            "Claude/GPT weekly",
        ])
        #expect(windows.map(\.window.windowMinutes) == [300, 10080, 300, 10080])
        #expect(windows.map { $0.window.remainingPercent.rounded() } == [91, 82, 73, 64])
        #expect(windows.map(\.usageKnown) == [true, true, true, true])

        let expectedDates = [
            ISO8601DateFormatter().date(from: "2026-06-15T11:39:34Z"),
            ISO8601DateFormatter().date(from: "2026-06-19T08:45:39Z"),
            ISO8601DateFormatter().date(from: "2026-06-15T12:52:10Z"),
            ISO8601DateFormatter().date(from: "2026-06-20T00:39:54Z"),
        ]
        #expect(windows.map(\.window.resetsAt) == expectedDates)

        #expect(usage.primary?.remainingPercent.rounded() == 82)
        #expect(usage.secondary?.remainingPercent.rounded() == 64)
        #expect(usage.tertiary == nil)
    }

    @Test
    func `parses quota summary oneof remaining value shape`() throws {
        let json = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit",
                  "remaining": { "case": "remainingFraction", "value": 0.5 }
                }
              ]
            }
          ]
        }
        """

        let snapshot = try AntigravityStatusProbe.parseQuotaSummaryResponse(Data(json.utf8))
        let usage = try snapshot.toUsageSnapshot()

        #expect(usage.extraRateWindows?.first?.window.remainingPercent == 50)
    }

    @Test
    func `fetch snapshot prefers quota summary endpoint and merges identity`() async throws {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "token",
            source: .languageServer)
        let paths = AntigravityQuotaSummaryPathRecorder()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(endpoints: [endpoint], timeout: 1),
            send: { payload, _, _ in
                paths.append(payload.path)
                if payload.path.contains("GetUserStatus") {
                    return Data(antigravityUserStatusJSON().utf8)
                }
                return Data(antigravityQuotaSummaryJSON().utf8)
            })
        let usage = try snapshot.toUsageSnapshot()

        #expect(paths.snapshot() == [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        ])
        #expect(usage.extraRateWindows?.count == 4)
        #expect(usage.identity?.accountEmail == "test@example.com")
        #expect(usage.identity?.loginMethod == "Pro")
    }

    @Test
    func `fetch snapshot keeps quota summary when identity endpoint fails`() async throws {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "token",
            source: .languageServer)
        let paths = AntigravityQuotaSummaryPathRecorder()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(endpoints: [endpoint], timeout: 1),
            send: { payload, _, _ in
                paths.append(payload.path)
                if payload.path.contains("GetUserStatus") {
                    return Data(#"{"code":16}"#.utf8)
                }
                return Data(antigravityQuotaSummaryJSON().utf8)
            })
        let usage = try snapshot.toUsageSnapshot()

        #expect(paths.snapshot() == [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        ])
        #expect(usage.extraRateWindows?.count == 4)
        #expect(usage.identity?.accountEmail == nil)
    }

    @Test
    func `fetch snapshot falls back to user status when quota summary is unavailable`() async throws {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "token",
            source: .languageServer)
        let paths = AntigravityQuotaSummaryPathRecorder()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(endpoints: [endpoint], timeout: 1),
            send: { payload, _, _ in
                paths.append(payload.path)
                if payload.path.contains("RetrieveUserQuotaSummary") {
                    return Data(#"{"code":16}"#.utf8)
                }
                return Data(antigravityUserStatusJSON().utf8)
            })
        let usage = try snapshot.toUsageSnapshot()

        #expect(paths.snapshot() == [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        ])
        #expect(usage.primary?.remainingPercent.rounded() == 90)
    }

    @Test
    func `fetch snapshot falls back when quota summary has no known usage buckets`() async throws {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "token",
            source: .languageServer)
        let paths = AntigravityQuotaSummaryPathRecorder()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(endpoints: [endpoint], timeout: 1),
            send: { payload, _, _ in
                paths.append(payload.path)
                if payload.path.contains("RetrieveUserQuotaSummary") {
                    return Data(antigravityQuotaSummaryWithoutKnownUsageJSON().utf8)
                }
                return Data(antigravityUserStatusJSON().utf8)
            })
        let usage = try snapshot.toUsageSnapshot()

        #expect(paths.snapshot() == [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        ])
        #expect(usage.primary?.remainingPercent.rounded() == 90)
    }

    @Test
    func `quota summary timeout reserves deadline for legacy fallback`() async throws {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "token",
            source: .languageServer)
        let paths = AntigravityQuotaSummaryPathRecorder()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(
                endpoints: [endpoint],
                timeout: 1,
                deadline: Date().addingTimeInterval(2)),
            send: { payload, _, timeout in
                paths.append(payload.path)
                if payload.path.contains("RetrieveUserQuotaSummary") {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AntigravityStatusProbeError.timedOut
                }
                return Data(antigravityUserStatusJSON().utf8)
            })
        let usage = try snapshot.toUsageSnapshot()

        #expect(paths.snapshot() == [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        ])
        #expect(usage.primary?.remainingPercent.rounded() == 90)
    }

    @Test
    func `user status timeout reserves deadline for command model fallback`() async throws {
        let endpoint = AntigravityStatusProbe.AntigravityConnectionEndpoint(
            scheme: "https",
            port: 64440,
            csrfToken: "token",
            source: .languageServer)
        let paths = AntigravityQuotaSummaryPathRecorder()

        let snapshot = try await AntigravityStatusProbe.fetchSnapshot(
            context: AntigravityStatusProbe.RequestContext(
                endpoints: [endpoint],
                timeout: 1,
                deadline: Date().addingTimeInterval(2)),
            send: { payload, _, timeout in
                paths.append(payload.path)
                if payload.path.contains("RetrieveUserQuotaSummary") {
                    throw AntigravityStatusProbeError.apiError("unsupported")
                }
                if payload.path.contains("GetUserStatus") {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AntigravityStatusProbeError.timedOut
                }
                return Data(antigravityCommandModelConfigJSON().utf8)
            })
        let usage = try snapshot.toUsageSnapshot()

        #expect(paths.snapshot() == [
            "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            "/exa.language_server_pb.LanguageServerService/GetUserStatus",
            "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs",
        ])
        #expect(usage.primary?.remainingPercent.rounded() == 90)
    }
}

private func antigravityQuotaSummaryJSON() -> String {
    """
    {
      "response": {
        "description": "Within each group, models share a weekly limit and a 5-hour limit.",
        "groups": [
          {
            "displayName": "Gemini Models",
            "description": "Models within this group: Gemini Flash, Gemini Pro",
            "buckets": [
              {
                "bucketId": "gemini-weekly",
                "displayName": "Weekly Limit",
                "remaining": { "remainingFraction": 0.82 },
                "description": "You have used some of your weekly limit, it will fully refresh in 5 days, 11 hours.",
                "resetTime": "2026-06-19T08:45:39Z"
              },
              {
                "bucketId": "gemini-5h",
                "displayName": "Five Hour Limit",
                "remaining": { "remainingFraction": 0.91 },
                "description": "You have used some of your 5-hour limit, it will fully refresh in 4 hours.",
                "resetTime": "2026-06-15T11:39:34Z"
              }
            ]
          },
          {
            "displayName": "Claude and GPT models",
            "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
            "buckets": [
              {
                "bucketId": "3p-weekly",
                "displayName": "Weekly Limit",
                "remaining": { "remainingFraction": 0.64 },
                "description": "You have used some of your weekly limit, it will fully refresh in 6 days, 22 hours.",
                "resetTime": "2026-06-20T00:39:54Z"
              },
              {
                "bucketId": "3p-5h",
                "displayName": "Five Hour Limit",
                "remaining": { "remainingFraction": 0.73 },
                "description": "You have used some of your 5-hour limit, it will fully refresh in 3 hours, 38 minutes.",
                "resetTime": "2026-06-15T12:52:10Z"
              }
            ]
          }
        ]
      }
    }
    """
}

private func antigravityQuotaSummaryWithoutKnownUsageJSON() -> String {
    """
    {
      "response": {
        "groups": [
          {
            "displayName": "Gemini Models",
            "buckets": [
              {
                "bucketId": "gemini-weekly",
                "displayName": "Weekly Limit",
                "description": "Refreshes later."
              },
              {
                "bucketId": "gemini-5h",
                "displayName": "Five Hour Limit",
                "disabled": true,
                "remaining": { "remainingFraction": 0.5 }
              }
            ]
          }
        ]
      }
    }
    """
}

private func antigravityUserStatusJSON() -> String {
    """
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
              "label": "Gemini 3 Pro Low",
              "modelOrAlias": { "model": "gemini-3-pro-low" },
              "quotaInfo": { "remainingFraction": 0.9, "resetTime": "2025-12-24T10:00:00Z" }
            }
          ]
        }
      }
    }
    """
}

private func antigravityCommandModelConfigJSON() -> String {
    """
    {
      "clientModelConfigs": [
        {
          "label": "Gemini 3 Pro Low",
          "modelOrAlias": { "model": "gemini-3-pro-low" },
          "quotaInfo": { "remainingFraction": 0.9, "resetTime": "2025-12-24T10:00:00Z" }
        }
      ]
    }
    """
}
