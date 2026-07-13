import Foundation
import Testing
@testable import CodexBarCore

struct DeepSeekPlatformTokenImporterTests {
    @Test
    func `extracts plain user token`() {
        let token = "browser-user-token-1234567890"
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting(token) == token)
    }

    @Test
    func `extracts JSON encoded user token`() {
        let token = "browser-user-token-abcdefghij"
        let value = "{\"userToken\":\"\(token)\"}"
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting(value) == token)
    }

    @Test
    func `extracts DeepSeek value wrapped user token`() {
        let token = "browser-user-token-value-wrapped"
        let value = "{\"value\":\"\(token)\",\"expiresAt\":1234567890}"
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting(value) == token)
    }

    @Test
    func `does not treat an unrecognized JSON object as a token`() {
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting("{\"expiresAt\":1234567890}") == nil)
    }

    @Test
    func `rejects short or whitespace values`() {
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting("short") == nil)
        #expect(DeepSeekPlatformTokenImporter._extractUserTokenForTesting("token with embedded spaces 12345") == nil)
    }

    @Test
    func `multiple profiles expose only server accepted sessions`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "valid-1"),
            Self.candidate(id: "profile-2", token: "expired"),
            Self.candidate(id: "profile-3", token: "valid-3"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: nil,
            validate: { token in
                guard token != "expired" else { throw DeepSeekUsageError.invalidPlatformToken }
                return Self.summary(marker: token == "valid-1" ? 1 : 3)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-1", "profile-3"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    @Test
    func `single accepted profile is selected automatically`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "expired-1"),
            Self.candidate(id: "profile-2", token: "valid-2"),
            Self.candidate(id: "profile-3", token: "expired-3"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: nil,
            validate: { token in
                guard token == "valid-2" else { throw DeepSeekUsageError.invalidPlatformToken }
                return Self.summary(marker: 2)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-2"])
        #expect(resolution.selectedSummary?.todayTokens == 2)
        #expect(resolution.detailedUsageState == .available)
    }

    @Test
    func `explicit selection requirement does not auto select a single accepted profile`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [Self.candidate(id: "profile-1", token: "valid-1")],
            selectedProfileID: nil,
            requiresExplicitSelection: true,
            validate: { _ in Self.summary(marker: 1) })

        #expect(resolution.profiles.map(\.id) == ["profile-1"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    @Test
    func `stored selection chooses one of multiple accepted profiles`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "valid-1"),
            Self.candidate(id: "profile-2", token: "valid-2"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: "profile-2",
            validate: { token in
                Self.summary(marker: token == "valid-1" ? 1 : 2)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-1", "profile-2"])
        #expect(resolution.selectedSummary?.todayTokens == 2)
        #expect(resolution.detailedUsageState == .available)
    }

    @Test
    func `expired stored selection does not silently switch to another profile`() async {
        let candidates = [
            Self.candidate(id: "profile-1", token: "expired"),
            Self.candidate(id: "profile-2", token: "valid-2"),
        ]

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: candidates,
            selectedProfileID: "profile-1",
            validate: { token in
                guard token == "valid-2" else { throw DeepSeekUsageError.invalidPlatformToken }
                return Self.summary(marker: 2)
            })

        #expect(resolution.profiles.map(\.id) == ["profile-2"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .profileSelectionRequired)
    }

    @Test
    func `temporary validation failure is unavailable rather than signed out`() async {
        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [Self.candidate(id: "profile-1", token: "maybe-valid")],
            selectedProfileID: nil,
            validate: { _ in throw DeepSeekUsageError.networkError("offline") })

        #expect(resolution.profiles.isEmpty)
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .unavailable)
    }

    @Test
    func `temporary validation failure keeps a previously accepted profile`() async {
        let candidate = Self.candidate(id: "profile-1", token: "valid-1")
        let cache = DeepSeekPlatformValidationCache(validityTTL: 0)
        _ = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [candidate],
            selectedProfileID: nil,
            cache: cache,
            validate: { _ in Self.summary(marker: 1) })

        let resolution = await DeepSeekPlatformTokenImporter._resolveForTesting(
            candidates: [candidate],
            selectedProfileID: nil,
            cache: cache,
            validate: { _ in throw DeepSeekUsageError.networkError("offline") })

        #expect(resolution.profiles.map(\.id) == ["profile-1"])
        #expect(resolution.selectedSummary == nil)
        #expect(resolution.detailedUsageState == .unavailable)
    }

    private static func candidate(id: String, token: String) -> DeepSeekPlatformTokenImporter.TokenInfo {
        DeepSeekPlatformTokenImporter.TokenInfo(id: id, token: token, sourceLabel: "Chrome \(id)")
    }

    private static func summary(marker: Int) -> DeepSeekUsageSummary {
        DeepSeekUsageSummary(
            todayTokens: marker,
            currentMonthTokens: marker,
            todayCost: nil,
            currentMonthCost: nil,
            requestCount: marker,
            currentMonthRequestCount: marker,
            topModel: nil,
            categoryBreakdown: [],
            daily: [],
            currency: "USD",
            updatedAt: Date(timeIntervalSince1970: 0))
    }
}
