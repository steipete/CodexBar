import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CompactOverviewSettingsTests {
    private static let layoutKey = "mergedOverviewLayout"
    private static let legacyCompactKey = "mergedOverviewUsesCompactLayout"

    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        func get() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `overview layout defaults to detailed without writing defaults`() throws {
        let suite = "CompactOverviewSettingsTests-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let store = Self.makeStore(defaults: defaults, suite: suite)

        #expect(store.mergedOverviewLayout == .detailed)
        #expect(defaults.object(forKey: Self.layoutKey) == nil)
        #expect(defaults.object(forKey: Self.legacyCompactKey) == nil)
    }

    @Test
    func `legacy compact boolean migrates both values to the layout key`() throws {
        let scenarios: [(legacyCompact: Bool, expected: MergedOverviewLayout)] = [
            (false, .detailed),
            (true, .compact),
        ]

        for scenario in scenarios {
            let suite = "CompactOverviewSettingsTests-legacy-\(scenario.legacyCompact)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defaults.set(scenario.legacyCompact, forKey: Self.legacyCompactKey)

            let store = Self.makeStore(defaults: defaults, suite: suite)

            #expect(store.mergedOverviewLayout == scenario.expected)
            #expect(defaults.string(forKey: Self.layoutKey) == scenario.expected.rawValue)
            #expect(defaults.object(forKey: Self.legacyCompactKey) as? Bool == scenario.legacyCompact)
        }
    }

    @Test
    func `new layout key takes precedence and unknown values safely remain untouched`() throws {
        let validSuite = "CompactOverviewSettingsTests-new-key-precedence"
        let validDefaults = try #require(UserDefaults(suiteName: validSuite))
        validDefaults.removePersistentDomain(forName: validSuite)
        validDefaults.set(MergedOverviewLayout.providerBars.rawValue, forKey: Self.layoutKey)
        validDefaults.set(false, forKey: Self.legacyCompactKey)

        let validStore = Self.makeStore(defaults: validDefaults, suite: validSuite)

        #expect(validStore.mergedOverviewLayout == .providerBars)
        #expect(validDefaults.string(forKey: Self.layoutKey) == MergedOverviewLayout.providerBars.rawValue)
        #expect(validDefaults.object(forKey: Self.legacyCompactKey) as? Bool == false)

        let unknownSuite = "CompactOverviewSettingsTests-unknown-new-key"
        let unknownDefaults = try #require(UserDefaults(suiteName: unknownSuite))
        unknownDefaults.removePersistentDomain(forName: unknownSuite)
        unknownDefaults.set("future-layout", forKey: Self.layoutKey)
        unknownDefaults.set(true, forKey: Self.legacyCompactKey)

        let unknownStore = Self.makeStore(defaults: unknownDefaults, suite: unknownSuite)

        #expect(unknownStore.mergedOverviewLayout == .detailed)
        #expect(unknownDefaults.string(forKey: Self.layoutKey) == "future-layout")
        #expect(unknownDefaults.object(forKey: Self.legacyCompactKey) as? Bool == true)
    }

    @Test
    func `all overview layouts round trip and dual write the legacy boolean`() throws {
        let layouts = MergedOverviewLayout.allCases
        let expectedLegacyCompactValues = [false, true, true, true]
        #expect(layouts == [.detailed, .compact, .providerBars, .barsOnly])

        for (layout, expectedLegacyCompact) in zip(layouts, expectedLegacyCompactValues) {
            let suite = "CompactOverviewSettingsTests-round-trip-\(layout.rawValue)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let configStore = testConfigStore(suiteName: suite)
            let store = Self.makeStore(defaults: defaults, configStore: configStore)

            store.mergedOverviewLayout = layout

            #expect(store.mergedOverviewLayout == layout)
            #expect(defaults.string(forKey: Self.layoutKey) == layout.rawValue)
            #expect(defaults.object(forKey: Self.legacyCompactKey) as? Bool == expectedLegacyCompact)

            let reloaded = Self.makeStore(defaults: defaults, configStore: configStore)
            #expect(reloaded.mergedOverviewLayout == layout)
        }
    }

    @Test
    func `changing compact to provider bars refreshes only menus`() async throws {
        let suite = "CompactOverviewSettingsTests-menu-observation"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = Self.makeStore(defaults: defaults, configStore: configStore)
        store.mergedOverviewLayout = .compact

        let configEncoder = JSONEncoder()
        configEncoder.outputFormatting = .sortedKeys
        let configData = try configEncoder.encode(store.configSnapshot)
        let configRevision = store.configRevision
        let backgroundRevision = store.backgroundWorkSettingsRevision
        let providerDetailRevision = store.providerDetailSettingsRevision
        let costUsageRevision = store.costUsageSettingsRevision
        let menuDidChange = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            menuDidChange.set()
        }

        store.mergedOverviewLayout = .providerBars
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.mergedOverviewLayout == .providerBars)
        #expect(menuDidChange.get())
        #expect(try configEncoder.encode(store.configSnapshot) == configData)
        #expect(store.configRevision == configRevision)
        #expect(store.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(store.providerDetailSettingsRevision == providerDetailRevision)
        #expect(store.costUsageSettingsRevision == costUsageRevision)
    }

    private static func makeStore(defaults: UserDefaults, suite: String) -> SettingsStore {
        self.makeStore(defaults: defaults, configStore: testConfigStore(suiteName: suite))
    }

    private static func makeStore(defaults: UserDefaults, configStore: CodexBarConfigStore) -> SettingsStore {
        SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
