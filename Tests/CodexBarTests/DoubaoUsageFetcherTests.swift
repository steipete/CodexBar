import Foundation
import Testing
@testable import CodexBarCore

struct DoubaoUsageSnapshotTests {
    @Test
    func `normal usage with both headers present and non-empty reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 750,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "250/1000 requests")
    }

    @Test
    func `boundary normal usage at near-full reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 1,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 99.9)
        #expect(usage.primary?.resetDescription == "999/1000 requests")
    }

    @Test
    func `unreliable headers omit the request limit window`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true,
            requestLimitsReliable: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `explicit rate limit with zero remaining reports exhausted quota`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
    }

    @Test
    func `both headers missing but key valid omit the request limit window`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `invalid key with no headers reports No usage data`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "No usage data")
    }

    @Test
    func `provider identity is correctly tagged as doubao`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 500,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.accountEmail == nil)
    }
}

struct DoubaoUsageFetcherTests {
    @Test
    func `coding plan response maps session weekly and monthly windows`() throws {
        let data = Data(
            """
            {
              "ResponseMetadata": {
                "Action": "GetCodingPlanUsage",
                "Version": "2024-01-01",
                "Service": "ark",
                "Region": "cn-beijing"
              },
              "Result": {
                "Status": "Running",
                "UpdateTimestamp": 1782226444,
                "QuotaUsage": [
                  {"Level":"session","Percent":0.116,"ResetTimestamp":1782226478},
                  {"Level":"weekly","Percent":3.182143,"ResetTimestamp":1782662400},
                  {"Level":"monthly","Percent":7.5730535,"ResetTimestamp":1782403199}
                ]
              }
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeCodingPlanUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary?.usedPercent == 0.116)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_782_226_478))
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 3.182143)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 7.5730535)
        #expect(usage.tertiary?.windowMinutes == 43200)
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.loginMethod == "Running")
    }

    @Test
    func `coding plan response ignores missing reset sentinels`() throws {
        let fallbackUpdatedAt = Date(timeIntervalSince1970: 42)
        let data = Data(
            """
            {
              "Result": {
                "Status": "Running",
                "UpdateTimestamp": 0,
                "QuotaUsage": [
                  {"Level":"session","Percent":12.5,"ResetTimestamp":0},
                  {"Level":"weekly","Percent":24,"ResetTimestamp":-1}
                ]
              }
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeCodingPlanUsage(from: data).toUsageSnapshot(
            updatedAt: fallbackUpdatedAt)

        #expect(usage.updatedAt == fallbackUpdatedAt)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 24)
        #expect(usage.secondary?.resetsAt == nil)
        #expect(usage.secondary?.resetDescription == nil)
    }

    @Test
    func `coding plan fetch signs volcengine request`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .rawResponse(
                statusCode: 200,
                body: """
                {
                  "Result": {
                    "Status": "Running",
                    "UpdateTimestamp": 1782226444,
                    "QuotaUsage": [
                      {"Level":"session","Percent":12.5,"ResetTimestamp":1782226478}
                    ]
                  }
                }
                """),
        ])
        let credentials = DoubaoCodingPlanCredentials(
            accessKeyID: "AKLTTEST",
            secretAccessKey: "secret",
            region: "cn-beijing")
        let date = Date(timeIntervalSince1970: 1_781_654_400)

        let snapshot = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
            credentials: credentials,
            session: transport,
            date: date)
        let request = await transport.lastCapturedRequest()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 12.5)
        #expect(request?.method == "POST")
        #expect(request?.url == "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")
        #expect(request?.host == "open.volcengineapi.com")
        #expect(request?.date == "20260617T000000Z")
        #expect(request?.contentSHA256 ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(request?.authorization?.contains(
            "HMAC-SHA256 Credential=AKLTTEST/20260617/cn-beijing/ark/request") == true)
        #expect(request?.authorization?.contains(
            "SignedHeaders=content-type;host;x-content-sha256;x-date") == true)
    }

    @Test
    func `coding plan fetch surfaces volcengine access denied error`() async {
        let transport = DoubaoScriptedTransport(results: [
            .rawResponse(
                statusCode: 403,
                body: """
                {
                  "ResponseMetadata": {
                    "Action": "GetCodingPlanUsage",
                    "Error": {
                      "CodeN": 100013,
                      "Code": "AccessDenied",
                      "Message": "User is not authorized to perform: ark:GetCodingPlanUsage"
                    }
                  }
                }
                """),
        ])
        let credentials = DoubaoCodingPlanCredentials(
            accessKeyID: "AKLTTEST",
            secretAccessKey: "secret",
            region: "cn-beijing")

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
                credentials: credentials,
                session: transport,
                date: Date(timeIntervalSince1970: 1_781_654_400))
        } throws: { error in
            guard case let DoubaoUsageError.apiError(code, message) = error else { return false }
            return code == 403
                && message.contains("AccessDenied")
                && message.contains("ark:GetCodingPlanUsage")
                && !message.contains("bytes")
        }
    }

    @Test
    func `arkcli response maps coding plan and agent plan windows`() throws {
        let data = Data(
            """
            {
              "viewer": {
                "auth_method": "sso",
                "profile": "agent-plan_cn-beijing_personal"
              },
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "5h", "total": 2000, "percent": 0},
                    {
                      "label": "weekly", "used": 2009.33, "total": 7000, "percent": 28.7,
                      "reset_at": "2026-07-20T00:00:00+08:00"
                    },
                    {
                      "label": "monthly", "used": 2009.33, "total": 20000, "percent": 10.05,
                      "reset_at": "2026-08-14T23:59:59+08:00"
                    }
                  ]
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "session", "percent": 7.48, "reset_at": "2026-07-16T19:12:07+08:00"},
                    {"label": "weekly", "percent": 2.71, "reset_at": "2026-07-20T00:00:00+08:00"},
                    {"label": "monthly", "percent": 1.36, "reset_at": "2026-08-15T23:59:59+08:00"}
                  ],
                  "updated_at": 1784191193000
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        // Coding plan should be primary/secondary/tertiary
        #expect(usage.primary?.usedPercent == 7.48)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 2.71)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 1.36)
        #expect(usage.tertiary?.windowMinutes == 43200)

        // Agent plan should appear as extra rate windows
        let agentWindows = usage.extraRateWindows ?? []
        #expect(agentWindows.count == 3)
        #expect(agentWindows[0].title == "5-hour")
        #expect(agentWindows[0].window.usedPercent == 0)
        #expect(agentWindows[1].title == "Weekly")
        #expect(agentWindows[1].window.usedPercent == 28.7)
        #expect(agentWindows[2].title == "Monthly")
        #expect(agentWindows[2].window.usedPercent == 10.05)

        // Update time from coding-plan's updated_at
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_191_193))
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.loginMethod == "sso")
    }

    @Test
    func `arkcli response handles missing reset_at fields`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "periods": [
                    {"label": "session", "percent": 12.5},
                    {"label": "weekly", "percent": 24.0, "reset_at": "2026-07-20T00:00:00+08:00"}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 42))

        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.secondary?.usedPercent == 24.0)
        #expect(usage.secondary?.resetsAt != nil)
    }

    @Test
    func `arkcli response with only agent plan preserves agent window identity`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "5h", "total": 2000, "percent": 5.0, "reset_at": "2026-07-16T19:12:07+08:00"},
                    {"label": "weekly", "percent": 15.0, "reset_at": "2026-07-20T00:00:00+08:00"},
                    {"label": "monthly", "percent": 25.0, "reset_at": "2026-08-15T23:59:59+08:00"}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary == nil)
        let agentWindows = try #require(usage.extraRateWindows)
        #expect(agentWindows.map(\.id) == [
            "doubao-agent-session",
            "doubao-agent-weekly",
            "doubao-agent-monthly",
        ])
        #expect(agentWindows.map(\.window.usedPercent) == [5.0, 15.0, 25.0])
    }

    @Test
    func `arkcli team-only plans preserve product identities`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "agent-plan-team",
                  "edition": "team",
                  "subscribed": true,
                  "periods": [
                    {"label": "5h", "percent": 5.0},
                    {"label": "weekly", "percent": 15.0}
                  ]
                },
                {
                  "product": "coding-plan-team",
                  "edition": "team",
                  "subscribed": true,
                  "periods": [
                    {"label": "session", "percent": 7.48},
                    {"label": "monthly", "percent": 25.0}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary == nil)
        let windows = try #require(usage.extraRateWindows)
        #expect(windows.map(\.id) == [
            "doubao-coding-team-session",
            "doubao-coding-team-monthly",
            "doubao-agent-team-session",
            "doubao-agent-team-weekly",
        ])
        #expect(windows.map(\.window.usedPercent) == [7.48, 25.0, 5.0, 15.0])
    }

    @Test
    func `arkcli mixed personal and team plans keep every bucket`() throws {
        let data = Data(
            """
            {
              "items": [
                {"product":"coding-plan","periods":[{"label":"session","percent":1}]},
                {"product":"coding-plan-team","periods":[{"label":"session","percent":2}]},
                {"product":"agent-plan","periods":[{"label":"5h","percent":3}]},
                {"product":"agent-plan-team","periods":[{"label":"5h","percent":4}]}
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary?.usedPercent == 1)
        let windows = try #require(usage.extraRateWindows)
        #expect(windows.map(\.id) == [
            "doubao-agent-session",
            "doubao-coding-team-session",
            "doubao-agent-team-session",
        ])
        #expect(windows.map(\.window.usedPercent) == [3, 2, 4])
    }

    @Test
    func `arkcli response with an error-only item still decodes valid buckets`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "error": "failed to query usage",
                  "subscribed": false
                },
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "5h", "percent": 5.0, "reset_at": "2026-07-16T19:12:07+08:00"}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        // The error-only coding item is skipped; the agent item still decodes.
        #expect(usage.primary == nil)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 5.0)
        #expect(usage.identity?.loginMethod == nil)
    }

    @Test
    func `arkcli explicitly unsubscribed bucket does not contribute stale periods`() throws {
        let data = Data(
            """
            {"items":[
              {
                "product":"coding-plan", "subscribed":false, "updated_at":1784199993,
                "periods":[{"label":"session","percent":99}]
              },
              {
                "product":"agent-plan", "subscribed":true, "updated_at":1784191193,
                "periods":[{"label":"5h","percent":5}]
              }
            ]}
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary == nil)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 5)
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_191_193))
    }

    @Test
    func `arkcli subscribed bucket failure does not silently return partial usage`() {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [{"label": "session", "percent": 5}]
                },
                {
                  "product": "agent-plan-team",
                  "subscribed": true,
                  "error": "no seat bound to caller"
                }
              ]
            }
            """.utf8)

        #expect {
            _ = try DoubaoUsageFetcher.decodeArkcliUsage(from: data)
        } throws: { error in
            guard case let DoubaoUsageError.incompletePlanUsage(message) = error else { return false }
            return message == "no seat bound to caller"
        }
    }

    @Test
    func `arkcli active empty bucket without error does not silently return partial usage`() {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "periods": [{"label": "session", "percent": 5}]
                },
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": []
                }
              ]
            }
            """.utf8)

        #expect {
            _ = try DoubaoUsageFetcher.decodeArkcliUsage(from: data)
        } throws: { error in
            guard case let DoubaoUsageError.incompletePlanUsage(message) = error else { return false }
            return message == "agent-plan has no usage periods"
        }
    }

    @Test
    func `arkcli viewer with no authentication requires login`() {
        let data = Data(
            """
            {
              "viewer": {"auth_method": "none"},
              "items": [
                {"product": "coding-plan", "periods": [{"label": "session", "percent": 5}]}
              ]
            }
            """.utf8)

        #expect {
            _ = try DoubaoUsageFetcher.decodeArkcliUsage(from: data)
        } throws: { error in
            guard case DoubaoUsageError.arkcliAuthenticationRequired = error else { return false }
            return true
        }
    }

    @Test
    func `arkcli response with only a failed bucket surfaces its error`() {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "error": "failed to query usage",
                  "subscribed": false
                }
              ]
            }
            """.utf8)

        #expect {
            _ = try DoubaoUsageFetcher.decodeArkcliUsage(from: data)
        } throws: { error in
            guard case let DoubaoUsageError.noPlanUsage(message) = error else { return false }
            return message == "failed to query usage"
        }
    }

    @Test
    func `arkcli response with no plan items is not treated as valid usage`() {
        #expect {
            _ = try DoubaoUsageFetcher.decodeArkcliUsage(from: Data(#"{"items":[]}"#.utf8))
        } throws: { error in
            guard case DoubaoUsageError.noPlanUsage(nil) = error else { return false }
            return true
        }
    }

    @Test
    func `arkcli response ignores unrelated product buckets`() {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "unrelated-plan",
                  "periods": [{"label": "session", "percent": 99}]
                }
              ]
            }
            """.utf8)

        #expect {
            _ = try DoubaoUsageFetcher.decodeArkcliUsage(from: data)
        } throws: { error in
            guard case DoubaoUsageError.noPlanUsage(nil) = error else { return false }
            return true
        }
    }

    @Test
    func `arkcli unrelated product failure does not poison valid plan usage`() throws {
        let data = Data(
            """
            {"items":[
              {
                "product":"future-plan", "subscribed":true,
                "error":"future product unavailable"
              },
              {
                "product":"coding-plan", "subscribed":true,
                "periods":[{"label":"session","percent":7}]
              }
            ]}
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary?.usedPercent == 7)
    }

    @Test
    func `arkcli response accepts updated_at in seconds`() throws {
        // Real arkcli output (0.1.x) emits `updated_at` in epoch seconds, not
        // milliseconds. Verify the auto-detection picks the right unit so the
        // menu doesn't show a 1970 timestamp.
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "session", "percent": 27.3, "reset_at": "2026-07-17T19:22:45+08:00"}
                  ],
                  "updated_at": 1784270829
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_270_829))
    }

    @Test
    func `arkcli response accepts numeric reset timestamps and sentinels`() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "periods": [
                    {"label": "session", "percent": 10, "reset_at": 1784192000},
                    {"label": "weekly", "percent": 20, "reset_at": 1784534400000},
                    {"label": "monthly", "percent": 30, "reset_at": -1}
                  ]
                }
              ]
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_784_192_000))
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_784_534_400))
        #expect(usage.tertiary?.resetsAt == nil)
    }

    @Test
    func `arkcli fetch via injected runner returns parsed snapshot`() async throws {
        let jsonData = Data(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    {"label": "session", "percent": 42.0, "reset_at": "2026-07-16T19:12:07+08:00"}
                  ],
                  "updated_at": 1784191193000
                }
              ]
            }
            """.utf8)

        let snapshot = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
            runArkcli: { jsonData },
            date: Date(timeIntervalSince1970: 0))

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 42.0)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.updatedAt == Date(timeIntervalSince1970: 1_784_191_193))
    }

    @Test
    func `arkcli aggregate freshness uses newest contributing bucket`() throws {
        let olderFirst = Data(
            """
            {"items":[
              {
                "product":"coding-plan", "updated_at":1784191193,
                "periods":[{"label":"session","percent":1}]
              },
              {
                "product":"agent-plan", "updated_at":1784191293000,
                "periods":[{"label":"5h","percent":2}]
              }
            ]}
            """.utf8)
        let newerFirst = Data(
            """
            {"items":[
              {
                "product":"agent-plan", "updated_at":1784191293000,
                "periods":[{"label":"5h","percent":2}]
              },
              {
                "product":"coding-plan", "updated_at":1784191193,
                "periods":[{"label":"session","percent":1}]
              }
            ]}
            """.utf8)

        let expected = Date(timeIntervalSince1970: 1_784_191_293)
        #expect(try DoubaoUsageFetcher.decodeArkcliUsage(from: olderFirst).updateTime == expected)
        #expect(try DoubaoUsageFetcher.decodeArkcliUsage(from: newerFirst).updateTime == expected)
    }

    @Test
    func `arkcli subprocess explicitly requests JSON output`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-arkcli-arguments-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("arkcli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        if [ "$*" != "usage plan --format json" ]; then
          printf '%s\n' "unexpected arguments: $*" >&2
          exit 2
        fi
        printf '%s\n' '{"items":[{"product":"coding-plan","periods":[{"label":"session","percent":42}]}]}'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let snapshot = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
            environment: ["ARKCLI_PATH": executable.path])

        #expect(snapshot.codingPlanUsage?.quotas.first?.percent == 42)
    }

    @Test
    func `arkcli subprocess uses discovery path for node interpreter`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-arkcli-node-path-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("arkcli")
        let node = root.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "#!/usr/bin/env node\n".write(to: executable, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\n' '{"items":[{"product":"coding-plan","periods":[{"label":"session","percent":42}]}]}'
        """.write(to: node, atomically: true, encoding: .utf8)
        for path in [executable.path, node.path] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        let data = try await DoubaoUsageFetcher.runArkcliUsagePlan(
            environment: ["PATH": "/usr/bin:/bin"],
            loginPATH: [root.path])
        let usage = try DoubaoUsageFetcher.decodeArkcliUsage(from: data)

        #expect(usage.quotas.first?.percent == 42)
    }

    @Test
    func `arkcli fetch surfaces parse error for invalid JSON`() async {
        await #expect {
            _ = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
                runArkcli: { Data("not json".utf8) })
        } throws: { error in
            guard case DoubaoUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `arkcli nonzero login error surfaces authentication guidance`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-arkcli-login-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("arkcli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        printf '%s\n' 'not logged in; run arkcli auth login' >&2
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
                environment: ["ARKCLI_PATH": executable.path])
        } throws: { error in
            guard case DoubaoUsageError.arkcliAuthenticationRequired = error else { return false }
            return error.localizedDescription.contains("arkcli auth login")
        }
    }

    @Test
    func `arkcli oversized stdout fails closed before JSON parsing`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-arkcli-output-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("arkcli")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        #!/bin/sh
        /usr/bin/head -c 300000 /dev/zero
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
                environment: ["ARKCLI_PATH": executable.path])
        } throws: { error in
            guard case DoubaoUsageError.arkcliOutputTooLarge = error else { return false }
            return true
        }
    }

    @Test
    func `missing arkcli error gives setup guidance`() {
        let message = DoubaoUsageError.arkcliNotFound.localizedDescription
        #expect(message.contains("Install arkcli"))
        #expect(message.contains("arkcli auth login"))
    }

    @Test
    func `repeated successful zero remaining responses omit unknown request limit`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 200, limit: 1000, remaining: 0),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `successful final request followed by rate limit reports exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 429, limit: 1000, remaining: 0),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `headerless rate limit confirmation preserves exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 429, limit: nil, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `rate limit with request limit header reports exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 429, limit: 1000, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 1)
    }

    @Test
    func `bare rate limit omits unknown request limit`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 429, limit: nil, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
        #expect(await transport.requestCount() == 1)
    }

    @Test
    func `failed zero remaining confirmation preserves exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .failure(URLError(.timedOut)),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `task cancellation during confirmation propagates`() async {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .cancellation,
        ])

        await #expect(throws: CancellationError.self) {
            _ = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        }
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `url cancellation during confirmation propagates`() async {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .failure(URLError(.cancelled)),
        ])

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }
        #expect(await transport.requestCount() == 2)
    }
}

private actor DoubaoScriptedTransport: ProviderHTTPTransport {
    enum Result {
        case response(statusCode: Int, limit: Int?, remaining: Int?)
        case rawResponse(statusCode: Int, body: String)
        case failure(URLError)
        case cancellation
    }

    struct CapturedRequest {
        let url: String?
        let method: String?
        let host: String?
        let date: String?
        let contentSHA256: String?
        let authorization: String?
    }

    private var results: [Result]
    private var requests = 0
    private var capturedRequest: CapturedRequest?

    init(results: [Result]) {
        self.results = results
    }

    func requestCount() -> Int {
        self.requests
    }

    func lastCapturedRequest() -> CapturedRequest? {
        self.capturedRequest
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests += 1
        self.capturedRequest = CapturedRequest(
            url: request.url?.absoluteString,
            method: request.httpMethod,
            host: request.value(forHTTPHeaderField: "Host"),
            date: request.value(forHTTPHeaderField: "X-Date"),
            contentSHA256: request.value(forHTTPHeaderField: "X-Content-Sha256"),
            authorization: request.value(forHTTPHeaderField: "Authorization"))
        let result = self.results.removeFirst()
        switch result {
        case let .response(statusCode, limit, remaining):
            var headers: [String: String] = [:]
            if let limit {
                headers["x-ratelimit-limit-requests"] = String(limit)
            }
            if let remaining {
                headers["x-ratelimit-remaining-requests"] = String(remaining)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            return (Data(#"{"usage":{"total_tokens":1}}"#.utf8), response)
        case let .rawResponse(statusCode, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [:])!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }
}
