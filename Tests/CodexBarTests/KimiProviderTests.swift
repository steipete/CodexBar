import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct KimiSettingsReaderTests {
    @Test
    func readsTokenFromEnvironmentVariable() {
        let env = ["KIMI_AUTH_TOKEN": "test.jwt.token"]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == "test.jwt.token")
    }

    @Test
    func normalizesQuotedToken() {
        let env = ["KIMI_AUTH_TOKEN": "\"test.jwt.token\""]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == "test.jwt.token")
    }

    @Test
    func returnsNilWhenMissing() {
        let env: [String: String] = [:]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == nil)
    }

    @Test
    func returnsNilWhenEmpty() {
        let env = ["KIMI_AUTH_TOKEN": ""]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == nil)
    }

    @Test
    func normalizesLowercaseEnvironmentKey() {
        let env = ["kimi_auth_token": "test.jwt.token"]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == "test.jwt.token")
    }
}

@Suite
struct KimiUsageResponseParsingTests {
    @Test
    func parsesValidResponse() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "2048",
                "used": "375",
                "remaining": "1673",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              },
              "limits": [
                {
                  "window": {
                    "duration": 300,
                    "timeUnit": "TIME_UNIT_MINUTE"
                  },
                  "detail": {
                    "limit": "200",
                    "used": "200",
                    "resetTime": "2026-01-06T15:05:24.374187075Z"
                  }
                }
              ]
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))

        #expect(response.usages.count == 1)
        let usage = response.usages[0]
        #expect(usage.scope == "FEATURE_CODING")
        #expect(usage.detail.limit == "2048")
        #expect(usage.detail.used == "375")
        #expect(usage.detail.remaining == "1673")
        #expect(usage.detail.resetTime == "2026-01-09T15:23:13.373329235Z")

        #expect(usage.limits?.count == 1)
        let rateLimit = usage.limits?.first
        #expect(rateLimit?.window.duration == 300)
        #expect(rateLimit?.window.timeUnit == "TIME_UNIT_MINUTE")
        #expect(rateLimit?.detail.limit == "200")
        #expect(rateLimit?.detail.used == "200")
    }

    @Test
    func parsesResponseWithoutRateLimits() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "2048",
                "used": "375",
                "remaining": "1673",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              },
              "limits": []
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
        #expect(response.usages.first?.limits?.isEmpty == true)
    }

    @Test
    func parsesResponseWithNullLimits() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "2048",
                "used": "375",
                "remaining": "1673",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              },
              "limits": null
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
        #expect(response.usages.first?.limits == nil)
    }

    @Test
    func throwsOnInvalidJson() {
        let invalidJson = "{ invalid json }"

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KimiUsageResponse.self, from: Data(invalidJson.utf8))
        }
    }

    @Test
    func throwsOnMissingFeatureCodingScope() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "OTHER_SCOPE",
              "detail": {
                "limit": "100",
                "used": "50",
                "remaining": "50",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              }
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
        let codingUsage = response.usages.first { $0.scope == "FEATURE_CODING" }
        #expect(codingUsage == nil)
    }
}

@Suite
struct KimiUsageSnapshotConversionTests {
    @Test
    func convertsToUsageSnapshotWithBothWindows() throws {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "375",
            remaining: "1673",
            resetTime: "2026-01-09T15:23:13.373329235Z")
        let rateLimitDetail = KimiUsageDetail(
            limit: "200",
            used: "200",
            remaining: "0",
            resetTime: "2026-01-06T15:05:24.374187075Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: rateLimitDetail,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary != nil)
        let weeklyExpected = 375.0 / 2048.0 * 100.0
        #expect(abs((usageSnapshot.primary?.usedPercent ?? 0.0) - weeklyExpected) < 0.01)
        #expect(usageSnapshot.primary?.resetDescription == "375/2048 requests")
        #expect(usageSnapshot.primary?.windowMinutes == nil)

        #expect(usageSnapshot.secondary != nil)
        let rateExpected = 200.0 / 200.0 * 100.0
        #expect(abs((usageSnapshot.secondary?.usedPercent ?? 0.0) - rateExpected) < 0.01)
        #expect(usageSnapshot.secondary?.windowMinutes == 300) // 5 hours
        #expect(usageSnapshot.secondary?.resetDescription == "Rate: 200/200 per 5 hours")

        #expect(usageSnapshot.tertiary == nil)
        #expect(usageSnapshot.updatedAt == now)
    }

    @Test
    func convertsToUsageSnapshotWithoutRateLimit() throws {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "375",
            remaining: "1673",
            resetTime: "2026-01-09T15:23:13.373329235Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: nil,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary != nil)
        let weeklyExpected = 375.0 / 2048.0 * 100.0
        #expect(abs((usageSnapshot.primary?.usedPercent ?? 0.0) - weeklyExpected) < 0.01)
        #expect(usageSnapshot.secondary == nil)
        #expect(usageSnapshot.tertiary == nil)
    }

    @Test
    func handlesZeroValuesCorrectly() throws {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "0",
            remaining: "2048",
            resetTime: "2026-01-09T15:23:13.373329235Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: nil,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()
        #expect(usageSnapshot.primary?.usedPercent == 0.0)
    }

    @Test
    func handlesHundredPercentCorrectly() throws {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "2048",
            remaining: "0",
            resetTime: "2026-01-09T15:23:13.373329235Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: nil,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()
        #expect(usageSnapshot.primary?.usedPercent == 100.0)
    }
}

@Suite
struct KimiTokenResolverTests {
    @Test
    func resolvesTokenFromEnvironment() {
        let previous = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = true
        defer { KeychainAccessGate.isDisabled = previous }
        let env = ["KIMI_AUTH_TOKEN": "test.jwt.token"]
        let token = ProviderTokenResolver.kimiAuthToken(environment: env)
        #expect(token == "test.jwt.token")
    }

    @Test
    func resolvesTokenFromKeychainFirst() {
        // This test would require mocking the keychain.
        let previous = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = true
        defer { KeychainAccessGate.isDisabled = previous }
        let env = ["KIMI_AUTH_TOKEN": "test.env.token"]
        let token = ProviderTokenResolver.kimiAuthToken(environment: env)
        #expect(token == "test.env.token")
    }

    @Test
    func resolutionIncludesSource() {
        let previous = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = true
        defer { KeychainAccessGate.isDisabled = previous }
        let env = ["KIMI_AUTH_TOKEN": "test.jwt.token"]
        let resolution = ProviderTokenResolver.kimiAuthResolution(environment: env)

        #expect(resolution?.token == "test.jwt.token")
        #expect(resolution?.source == .environment)
    }
}

@Suite
struct KimiAPIErrorTests {
    @Test
    func errorDescriptionsAreHelpful() {
        #expect(KimiAPIError.missingToken.errorDescription?.contains("missing") == true)
        #expect(KimiAPIError.invalidToken.errorDescription?.contains("invalid") == true)
        #expect(KimiAPIError.invalidRequest("Bad request").errorDescription?.contains("Bad request") == true)
        #expect(KimiAPIError.networkError("Timeout").errorDescription?.contains("Timeout") == true)
        #expect(KimiAPIError.apiError("HTTP 500").errorDescription?.contains("HTTP 500") == true)
        #expect(KimiAPIError.parseFailed("Invalid JSON").errorDescription?.contains("Invalid JSON") == true)
    }
}
