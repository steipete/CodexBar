import Foundation
import Testing
@testable import CodexBarCore

struct KimiSettingsReaderTests {
    @Test
    func `reads API key from preferred environment variable`() {
        let env = ["KIMI_CODE_API_KEY": "kimi-code-key"]
        #expect(KimiSettingsReader.apiKey(environment: env) == "kimi-code-key")
    }

    @Test
    func `falls back to KIMI API key`() {
        let env = ["KIMI_API_KEY": "\"kimi-api-key\""]
        #expect(KimiSettingsReader.apiKey(environment: env) == "kimi-api-key")
    }

    @Test
    func `returns nil when API key missing`() {
        #expect(KimiSettingsReader.apiKey(environment: [:]) == nil)
    }

    @Test
    func `builds credentials file URL under kimi home`() {
        let env = ["KIMI_HOME": "/tmp/custom-kimi"]
        let url = KimiSettingsReader.credentialsFileURL(environment: env)
        #expect(url.path == "/tmp/custom-kimi/credentials/kimi-code.json")
    }
}

struct KimiOAuthCredentialsTests {
    @Test
    func `loads credentials from file`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = ["KIMI_HOME": home.path]

        let credentials = KimiOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
            scope: "openid profile",
            tokenType: "Bearer",
            expiresIn: 3600)
        try KimiOAuthCredentialsStore.save(credentials, env: env)

        let loaded = try KimiOAuthCredentialsStore.load(env: env)
        #expect(loaded == credentials)
    }

    @Test
    func `credentials need refresh near expiry`() {
        let expiring = KimiOAuthCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(240).timeIntervalSince1970,
            scope: "",
            tokenType: "Bearer",
            expiresIn: 3600)

        #expect(expiring.needsRefresh == true)
    }
}

struct KimiUsageParsingTests {
    @Test
    func `parses Kimi Code usage payload`() throws {
        let json = """
        {
          "usage": {
            "limit": "2048",
            "used": "375",
            "remaining": "1673",
            "resetAt": "2026-01-09T15:23:13.373329235Z"
          },
          "limits": [
            {
              "window": {
                "duration": 300,
                "timeUnit": "TIME_UNIT_MINUTE"
              },
              "detail": {
                "limit": "200",
                "used": "139",
                "remaining": "61",
                "resetAt": "2026-01-06T13:33:02.717479433Z"
              }
            }
          ]
        }
        """

        let payload = try KimiUsageFetcher._parsePayloadForTesting(Data(json.utf8))

        #expect(payload.summary?.label == "Weekly limit")
        #expect(payload.summary?.used == 375)
        #expect(payload.summary?.limit == 2048)
        #expect(payload.summary?.windowMinutes == nil)
        #expect(payload.limits.count == 1)
        #expect(payload.limits.first?.label == "5h limit")
        #expect(payload.limits.first?.used == 139)
        #expect(payload.limits.first?.limit == 200)
        #expect(payload.limits.first?.windowMinutes == 300)
    }

    @Test
    func `parses limit from remaining when used is absent`() throws {
        let json = """
        {
          "usage": {
            "limit": "2048",
            "remaining": "2000"
          },
          "limits": []
        }
        """

        let payload = try KimiUsageFetcher._parsePayloadForTesting(Data(json.utf8))
        #expect(payload.summary?.used == 48)
    }

    @Test
    func `throws when no rows are present`() {
        let json = #"{"usage": null, "limits": []}"#

        #expect(throws: KimiAPIError.self) {
            try KimiUsageFetcher._parsePayloadForTesting(Data(json.utf8))
        }
    }
}

struct KimiUsageSnapshotConversionTests {
    @Test
    func `converts summary and first two limits`() {
        let now = Date()
        let snapshot = KimiUsageSnapshot(
            summary: KimiUsageRow(
                label: "Weekly limit",
                used: 375,
                limit: 2048,
                windowMinutes: nil,
                resetAt: "2026-01-09T15:23:13.373329235Z"),
            limits: [
                KimiUsageRow(
                    label: "5h limit",
                    used: 139,
                    limit: 200,
                    windowMinutes: 300,
                    resetAt: "2026-01-06T13:33:02.717479433Z"),
                KimiUsageRow(
                    label: "24h limit",
                    used: 80,
                    limit: 100,
                    windowMinutes: 1440,
                    resetAt: "2026-01-07T13:33:02.717479433Z"),
            ],
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(abs((usageSnapshot.primary?.usedPercent ?? 0) - (375.0 / 2048.0 * 100.0)) < 0.01)
        #expect(usageSnapshot.primary?.windowMinutes == nil)
        #expect(usageSnapshot.primary?.resetDescription == "375/2048")

        #expect(abs((usageSnapshot.secondary?.usedPercent ?? 0) - 69.5) < 0.01)
        #expect(usageSnapshot.secondary?.windowMinutes == 300)
        #expect(usageSnapshot.secondary?.resetDescription == "5h limit: 139/200")

        #expect(usageSnapshot.tertiary?.windowMinutes == 1440)
        #expect(usageSnapshot.updatedAt == now)
    }
}

struct KimiTokenResolverTests {
    @Test
    func `resolves API key from environment`() {
        let env = ["KIMI_API_KEY": "test-api-key"]
        let resolution = ProviderTokenResolver.kimiAPIKeyResolution(environment: env)

        #expect(resolution?.token == "test-api-key")
        #expect(resolution?.source == .environment)
    }
}

struct KimiAPIErrorTests {
    @Test
    func `error descriptions are helpful`() {
        #expect(KimiAPIError.missingToken.errorDescription?.contains("credentials") == true)
        #expect(KimiAPIError.invalidToken.errorDescription?.contains("expired") == true)
        #expect(KimiAPIError.invalidRequest("Bad request").errorDescription?.contains("Bad request") == true)
        #expect(KimiAPIError.networkError("Timeout").errorDescription?.contains("Timeout") == true)
        #expect(KimiAPIError.apiError("HTTP 500").errorDescription?.contains("HTTP 500") == true)
        #expect(KimiAPIError.parseFailed("Invalid JSON").errorDescription?.contains("Invalid JSON") == true)
    }
}
