import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AntigravityProfileHomesTests {
    @Test
    func `CLI config unions explicit profiles and deduplicates copied conversations`() throws {
        let primary = try AntigravityLocalFixture()
        let profile = try AntigravityLocalFixture()
        let blob = AntigravityLocalFixture.blob(model: "gemini-2.5-pro", seconds: UInt64(Date().timeIntervalSince1970))
        let original = try primary.database("primary-conversation", blobs: [blob])
        let additional = try profile.database("profile-conversation", rootIndex: 2, blobs: [blob])
        try FileManager.default.copyItem(
            at: original, to: additional.deletingLastPathComponent().appendingPathComponent(original.lastPathComponent))
        let configURL = primary.root.appendingPathComponent("config.json")
        let profileHome = profile.root.appendingPathComponent(".gemini").path
        for (homes, expected) in [([], 187), ([profileHome], 374), ([profileHome, profileHome], 374), ([], 187)] {
            let config: [String: Any] = ["version": 1, "providers": [[
                "id": "antigravity", "enabled": true, "antigravityAdditionalProfileHomes": homes,
            ]]]
            try JSONSerialization.data(withJSONObject: config).write(to: configURL)
            let process = Process()
            process.executableURL = TestBuildProducts.executableURL(named: "CodexBarCLI")
            process.arguments = ["cost", "--provider", "antigravity", "--json"]
            process.environment = [
                "HOME": primary.root.path, "CFFIXED_USER_HOME": primary.root.path,
                "CODEX_HOME": primary.root.appendingPathComponent(".codex").path,
                "CODEXBAR_CONFIG": configURL.path, "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
                "CODEXBAR_TEST_SESSION_FILE_ISOLATION": "1", "CODEXBAR_TEST_CODEX_FILE_ISOLATION": "1",
                "PATH": "/usr/bin:/bin", "TZ": "UTC",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(payload.first?["last30DaysTokens"] as? Int == expected)
        }
    }

    @Test @MainActor
    func `profile home changes invalidate menu and dashboard history scopes`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(
            suite: "antigravity-profile-scope", environmentBase: ["HOME": "/synthetic-home"])
        let menu = fixture.store.tokenSnapshotScopeSignature(for: .antigravity)
        let dashboard = fixture.store.spendDashboardTokenSnapshotScopeSignature(for: .antigravity)
        fixture.store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 187,
                sessionCostUSD: nil,
                last30DaysTokens: 187,
                last30DaysCostUSD: nil,
                daily: [],
                updatedAt: AntigravityLocalFixture.now),
            provider: .antigravity)
        #expect(fixture.store.tokenSnapshotPublicationForCurrentProviderConfig(for: .antigravity) != nil)
        #expect(fixture.store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .antigravity) != nil)
        fixture.settings.updateProviderConfig(provider: .antigravity) {
            $0.setExtensionValue(["/synthetic-profile/.gemini"], forKey: "antigravityAdditionalProfileHomes")
        }
        #expect(fixture.store.tokenSnapshotScopeSignature(for: .antigravity) != menu)
        #expect(fixture.store.spendDashboardTokenSnapshotScopeSignature(for: .antigravity) != dashboard)
        #expect(fixture.store.tokenSnapshotPublicationForCurrentProviderConfig(for: .antigravity) == nil)
        #expect(fixture.store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .antigravity) == nil)
        fixture.settings.antigravityAdditionalProfileHomes = []
        #expect(fixture.store.tokenSnapshotScopeSignature(for: .antigravity) == menu)
        #expect(fixture.store.spendDashboardTokenSnapshotScopeSignature(for: .antigravity) == dashboard)
    }
}
