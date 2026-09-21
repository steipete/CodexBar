import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct KimiRegionSettingsTests {
    @Test
    func `render synthetic Kimi settings when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_KIMI_REGION_PROOF"] else { return }
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.updateProviderConfig(provider: .kimi) { $0.region = "international" }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = Self.context(settings: settings, store: store)
        let pickers = KimiProviderImplementation().settingsPickers(context: context)
        let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 18) {
            Text("Kimi Code").font(.title2.bold())
            Text("Synthetic settings · International account").font(.caption).foregroundStyle(.secondary)
            ForEach(pickers) { ProviderSettingsPickerRowView(picker: $0) }
        }.padding(24).frame(width: 700).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    @Test
    func `region picker persists and reaches runtime settings and dashboard dispatch`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        #expect(settings.kimiRegion == .china)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let implementation = KimiProviderImplementation()
        let context = Self.context(settings: settings, store: store)
        let picker = try #require(implementation.settingsPickers(context: context).first { $0.id == "kimi-region" })
        #expect(picker.options.map(\.id) == ["china", "international"])
        for region in KimiRegion.allCases {
            picker.binding.wrappedValue = region.rawValue
            #expect(settings.kimiRegion == region)
            let saved = try JSONDecoder().decode(
                CodexBarConfig.self,
                from: JSONEncoder().encode(settings.configSnapshot))
            let reloaded = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults(), config: saved)
            #expect(reloaded.kimiRegion == region)
            let section = try #require(implementation.settingsSnapshot(context: .init(
                settings: reloaded,
                tokenOverride: nil)))
            #expect(ProviderSettingsSnapshot(contributions: [section]).kimi?.region == region)
            withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
                #expect(controller.dashboardURL(for: .kimi) == region.consoleURL)
            }
        }
        picker.binding.wrappedValue = "unknown"
        #expect(settings.kimiRegion == .china)
    }

    private static func context(settings: SettingsStore, store: UsageStore) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: .kimi,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
    }
}
