import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct DebugPaneProviderOrderTests {
    private static func displayName(_ provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }

    private static func assertSortedByDisplayName(_ providers: [UsageProvider]) {
        let names = providers.map(Self.displayName)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test
    func `fetch strategy provider list is sorted by display name and complete`() {
        let providers = DebugPane.fetchStrategyProviders
        Self.assertSortedByDisplayName(providers)
        #expect(Set(providers) == Set(UsageProvider.allCases))
        #expect(providers.count == UsageProvider.allCases.count)
    }

    @Test
    func `probe log and notification provider lists are sorted by display name`() {
        Self.assertSortedByDisplayName(DebugPane.probeLogProviders)
        Self.assertSortedByDisplayName(DebugPane.notificationSimulationProviders)
        #expect(Set(DebugPane.probeLogProviders) == [.codex, .claude, .cursor, .augment, .amp, .ollama])
        #expect(Set(DebugPane.notificationSimulationProviders) == [.codex, .claude])
    }

    #if DEBUG
    @Test
    func `error simulation provider list is sorted by display name`() {
        Self.assertSortedByDisplayName(DebugPane.errorSimulationProviders)
    }
    #endif
}
