import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HelmcodeProviderDescriptorTests {
    @Test
    func `descriptor and app implementation are registered`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .helmcode)
        #expect(descriptor.metadata.displayName == "Helmcode")
        #expect(descriptor.metadata.browserCookieOrder == [.chrome])
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web])
        #expect(descriptor.branding.color == ProviderColor(hex: 0x4934E1))
        #expect(try #require(ProviderImplementationRegistry.implementation(for: .helmcode))
            is HelmcodeProviderImplementation)

        let quotaURL = try #require(Bundle.module.url(
            forResource: "quota",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Helmcode"))
        let snapshot = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(contentsOf: quotaURL),
            creditsData: nil).toUsageSnapshot()
        #expect(descriptor.presentation.extraRateWindows(snapshot: snapshot).map(\.title) == [
            "deepseek-v4-flash",
            "glm5.2",
            "glm5.3",
            "mimo-v2.5",
            "qwen3.8-flash",
        ])
        #expect(descriptor.presentation.menu.usesPrimaryDescriptionAsDetail(snapshot: snapshot))
    }

    @Test @MainActor
    func `settings store persists deployment and feeds snapshots`() throws {
        let settings = testSettingsStore(suiteName: "HelmcodeProviderDescriptorTests-deployment")
        #expect(settings.helmcodeDeploymentSelection == .auto)
        #expect(settings.helmcodeSettingsSnapshot(tokenOverride: nil).deploymentSelection == .auto)

        settings.helmcodeDeploymentSelection = .nanBuilders
        #expect(settings.helmcodeDeploymentSelection == .nanBuilders)
        #expect(settings.providerConfig(for: .helmcode)?.region == "nanBuilders")

        let contribution = try ProviderDescriptorRegistry.descriptor(for: .helmcode)
            .settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(
                config: #require(settings.providerConfig(for: .helmcode)),
                account: nil))
        let cliSnapshot = contribution.map { ProviderSettingsSnapshot(contributions: [$0]) }
        #expect(cliSnapshot?.helmcode?.deploymentSelection == .nanBuilders)
    }
}
