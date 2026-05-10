import CodexBarCore
import Foundation
import Testing

struct StepFunSettingsReaderTests {
    @Test
    func `reads STEPFUN_TOKEN`() {
        let env = ["STEPFUN_TOKEN": "some-oasis-token-value"]
        #expect(StepFunSettingsReader.token(environment: env) == "some-oasis-token-value")
    }

    @Test
    func `reads STEPFUN_USERNAME`() {
        let env = ["STEPFUN_USERNAME": "user@example.com"]
        #expect(StepFunSettingsReader.username(environment: env) == "user@example.com")
    }

    @Test
    func `reads STEPFUN_PASSWORD`() {
        let env = ["STEPFUN_PASSWORD": "secret123"]
        #expect(StepFunSettingsReader.password(environment: env) == "secret123")
    }

    @Test
    func `trims whitespace from token`() {
        let env = ["STEPFUN_TOKEN": "  some-token  "]
        #expect(StepFunSettingsReader.token(environment: env) == "some-token")
    }

    @Test
    func `strips double quotes from token`() {
        let env = ["STEPFUN_TOKEN": "\"some-token\""]
        #expect(StepFunSettingsReader.token(environment: env) == "some-token")
    }

    @Test
    func `strips single quotes from token`() {
        let env = ["STEPFUN_TOKEN": "'some-token'"]
        #expect(StepFunSettingsReader.token(environment: env) == "some-token")
    }

    @Test
    func `returns nil when no env vars present`() {
        #expect(StepFunSettingsReader.token(environment: [:]) == nil)
        #expect(StepFunSettingsReader.username(environment: [:]) == nil)
        #expect(StepFunSettingsReader.password(environment: [:]) == nil)
    }

    @Test
    func `returns nil for empty values`() {
        let env = ["STEPFUN_TOKEN": "", "STEPFUN_USERNAME": "", "STEPFUN_PASSWORD": ""]
        #expect(StepFunSettingsReader.token(environment: env) == nil)
        #expect(StepFunSettingsReader.username(environment: env) == nil)
        #expect(StepFunSettingsReader.password(environment: env) == nil)
    }

    @Test
    func `returns nil for whitespace-only values`() {
        let env = ["STEPFUN_TOKEN": "   "]
        #expect(StepFunSettingsReader.token(environment: env) == nil)
    }
}

struct StepFunProviderTokenResolverTests {
    @Test
    func `resolves token from environment`() {
        let env = ["STEPFUN_TOKEN": "my-test-token"]
        let resolution = ProviderTokenResolver.stepfunResolution(environment: env)
        #expect(resolution?.token == "my-test-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `returns nil when token absent`() {
        let resolution = ProviderTokenResolver.stepfunResolution(environment: [:])
        #expect(resolution == nil)
    }
}

struct StepFunUsageFetcherParsingTests {
    @Test
    func `parses real API response format with string timestamps and integer rates`() throws {
        // This matches the actual StepFun API response format:
        // - timestamps as strings (e.g. "1777528800")
        // - rates can be integers (e.g. 1) or floats (e.g. 0.99781543)
        let json = """
        {
            "status": 1,
            "desc": "",
            "five_hour_usage_left_rate": 1,
            "five_hour_usage_reset_time": "1777528800",
            "weekly_usage_left_rate": 0.99781543,
            "weekly_usage_reset_time": "1777899600"
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)

        #expect(snapshot.fiveHourUsageLeftRate == 1.0)
        #expect(snapshot.weeklyUsageLeftRate > 0.997 && snapshot.weeklyUsageLeftRate < 0.998)
    }

    @Test
    func `parses response with float rates and integer timestamps`() throws {
        let json = """
        {
            "status": 1,
            "five_hour_usage_left_rate": 0.75,
            "weekly_usage_left_rate": 0.5,
            "five_hour_usage_reset_time": 1746000000,
            "weekly_usage_reset_time": 1746500000
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)

        #expect(snapshot.fiveHourUsageLeftRate == 0.75)
        #expect(snapshot.weeklyUsageLeftRate == 0.5)
    }

    @Test
    func `throws on failed API status`() {
        let json = """
        {
            "status": 0,
            "message": "Unauthorized",
            "five_hour_usage_left_rate": 0.75,
            "weekly_usage_left_rate": 0.5,
            "five_hour_usage_reset_time": "1746000000",
            "weekly_usage_reset_time": "1746500000"
        }
        """
        let data = Data(json.utf8)
        #expect(throws: StepFunUsageError.self) {
            try StepFunUsageFetcher._parseSnapshotForTesting(data)
        }
    }

    @Test
    func `throws on missing fields`() {
        let json = """
        {
            "status": 1
        }
        """
        let data = Data(json.utf8)
        #expect(throws: StepFunUsageError.self) {
            try StepFunUsageFetcher._parseSnapshotForTesting(data)
        }
    }

    @Test
    func `throws on invalid JSON`() {
        let data = Data("not json".utf8)
        #expect(throws: StepFunUsageError.self) {
            try StepFunUsageFetcher._parseSnapshotForTesting(data)
        }
    }

    @Test
    func `snapshot maps to UsageSnapshot correctly`() throws {
        let json = """
        {
            "status": 1,
            "five_hour_usage_left_rate": 0.8,
            "weekly_usage_left_rate": 0.6,
            "five_hour_usage_reset_time": "1746000000",
            "weekly_usage_reset_time": "1746500000"
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)
        let usage = snapshot.toUsageSnapshot()

        // Five-hour window: 20% used (1.0 - 0.8)
        let primaryUsed = usage.primary?.usedPercent ?? 0
        #expect(primaryUsed > 19.9 && primaryUsed < 20.1)

        // Weekly window: 40% used (1.0 - 0.6)
        let secondaryUsed = usage.secondary?.usedPercent ?? 0
        #expect(secondaryUsed > 39.9 && secondaryUsed < 40.1)
        #expect(usage.secondary?.windowMinutes == 10080)

        // Identity
        #expect(usage.identity?.providerID == .stepfun)
        #expect(usage.identity?.loginMethod == "password")
    }

    @Test
    func `clamps used percent to 0-100 range`() throws {
        let json = """
        {
            "status": 1,
            "five_hour_usage_left_rate": 0.0,
            "weekly_usage_left_rate": 1,
            "five_hour_usage_reset_time": "1746000000",
            "weekly_usage_reset_time": "1746500000"
        }
        """
        let data = Data(json.utf8)
        let snapshot = try StepFunUsageFetcher._parseSnapshotForTesting(data)
        let usage = snapshot.toUsageSnapshot()

        // 0% remaining → 100% used
        #expect(usage.primary?.usedPercent == 100.0)
        // 100% remaining → 0% used (integer 1 parsed as 1.0)
        #expect(usage.secondary?.usedPercent == 0.0)
    }
}

struct StepFunTokenNormalizerTests {
    @Test
    func `extracts Oasis-Token from cookie header`() {
        let input = "Oasis-Token=abc123...def456; Oasis-Webid=someid"
        #expect(StepFunTokenNormalizer.normalize(input) == "abc123...def456")
    }

    @Test
    func `returns raw value when not a cookie header`() {
        let input = "abc123...def456"
        #expect(StepFunTokenNormalizer.normalize(input) == "abc123...def456")
    }

    @Test
    func `returns empty for empty string`() {
        #expect(StepFunTokenNormalizer.normalize("").isEmpty)
    }

    @Test
    func `trims whitespace`() {
        #expect(StepFunTokenNormalizer.normalize("  token123  ") == "token123")
    }
}
