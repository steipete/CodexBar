import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct SiliconFlowProviderTests {
    @Test
    func `API key and official origin use the standard settings fields`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SiliconFlowProviderTests")
        let implementation = try #require(ProviderCatalog.implementation(for: .siliconflow))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .siliconflow))
        #expect(fields.map(\.kind) == [.secure, .plain])
        #expect(fields.map(\.title) == ["API key", "API URL"])
        #expect(implementation.settingsPickers(context: fixture.settingsContext(provider: .siliconflow))
            .map(\.id) == ["siliconflow-usage-source"])
        #expect(ProviderSelection(argument: "SILICONFLOW")?.asList == [.siliconflow])
        let international = ["SILICONFLOW_BASE_URL": "https://api.siliconflow.com"]
        #expect(!implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: international)))
        fields[0].binding.wrappedValue = "sk-fixture"
        #expect(fixture.settings[providerConfig: .siliconflow, field: .apiKey] == "sk-fixture")
        #expect(implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))

        let descriptor = SiliconFlowProviderDescriptor.descriptor
        let credentials = try #require(descriptor.credentials)
        let environment = credentials.applyConfig(
            base: ["SILICONFLOW_API_KEY": "environment-fixture"],
            config: ProviderConfig(
                id: .siliconflow,
                apiKey: "sk-fixture",
                enterpriseHost: "https://api.siliconflow.com/v1/"))
        #expect(environment["SILICONFLOW_API_KEY"] == "sk-fixture")
        #expect(environment["SILICONFLOW_BASE_URL"] == "https://api.siliconflow.com/v1/")
        #expect(credentials.resolveToken(environment: environment)?.token == "sk-fixture")
        #expect(descriptor.metadata.balanceOnly)
        #expect(!descriptor.metadata.burnDownWidgetSelectable)
        #expect(descriptor.history == .unavailable)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .web, .api])
        let issues = credentials.validateConfig(ProviderConfig(
            id: .siliconflow,
            enterpriseHost: "https://example.com"))
        #expect(issues.map(\.code) == ["siliconflow_api_origin_invalid"])
    }

    @Test
    func `origin defaults to China and rejects every other host`() throws {
        #expect(SiliconFlowSettingsReader.baseURL(environment: [:]) == SiliconFlowSettingsReader.chinaOrigin)
        #expect(SiliconFlowSettingsReader.normalizedOrigin("api.siliconflow.cn/v1") ==
            SiliconFlowSettingsReader.chinaOrigin)
        #expect(SiliconFlowSettingsReader.normalizedOrigin("https://api.siliconflow.com/v1/") ==
            SiliconFlowSettingsReader.internationalOrigin)
        for raw in [
            "http://api.siliconflow.cn",
            "https://user:secret@api.siliconflow.cn",
            "https://api.siliconflow.cn.evil.com",
            "https://api.siliconflow.cn/v1/user/info",
            "https://api.siliconflow.cn?q=1",
            "https://api.siliconflow.cn#frag",
            "https://api.siliconflow.cn:443",
        ] {
            #expect(SiliconFlowSettingsReader.normalizedOrigin(raw) == nil, "accepted \(raw)")
        }
        #expect(throws: ProviderFetchClassifiedError.self) {
            try SiliconFlowSettingsReader.validate(environment: ["SILICONFLOW_BASE_URL": "https://example.com"])
        }
    }
}

extension SiliconFlowProviderTests {
    @Test
    func `render synthetic source settings when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_SILICONFLOW_PROOF_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        fixture.settings.debugDisableKeychainAccess = false
        let context = fixture.settingsContext(provider: .siliconflow)
        let implementation = SiliconFlowProviderImplementation()
        for stage in ["before", "after-auto", "after-web"] {
            fixture.settings.updateProviderConfig(provider: .siliconflow) {
                $0.source = stage == "after-web" ? .web : .auto
                $0.cookieSource = .manual
            }
            let fields = stage == "before"
                ? PluginAPIKeyProviderImplementation(spec: SiliconFlowProviderDescriptor.spec)
                .settingsFields(context: context)
                : implementation.settingsFields(context: context)
            let pickers = stage == "before" ? [] : implementation.settingsPickers(context: context)
            let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                Text("SiliconFlow").font(.title2.bold()).padding(20)
                Form {
                    ForEach(pickers) { ProviderSettingsPickerRowView(picker: $0) }
                    ForEach(fields.filter { $0.isVisible?() ?? true }) { ProviderSettingsFieldRowView(field: $0) }
                }.formStyle(.grouped)
            }
            .frame(width: 620, height: 750)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(.light))
            hosting.appearance = NSAppearance(named: .aqua)
            let png = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
            try png.write(to: directory.appendingPathComponent("siliconflow-\(stage).png"))
        }
    }

    @Test
    func `console links follow validated regional config before environment`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SiliconFlowRegionalLinks")
        let env = ["SILICONFLOW_BASE_URL": "https://api.siliconflow.com/v1/"]
        #expect(SiliconFlowProviderImplementation.dashboardURL(
            settings: fixture.settings, environment: [:])?.absoluteString == "https://cloud.siliconflow.cn")
        #expect(SiliconFlowProviderImplementation.dashboardURL(
            settings: fixture.settings, environment: env)?.absoluteString == "https://cloud.siliconflow.com")
        fixture.settings[providerConfig: .siliconflow, field: .endpoint] = "https://api.siliconflow.cn/v1"
        #expect(SiliconFlowProviderImplementation.dashboardURL(
            settings: fixture.settings, environment: env)?.absoluteString == "https://cloud.siliconflow.cn")
        fixture.settings[providerConfig: .siliconflow, field: .endpoint] = "https://untrusted.example"
        #expect(SiliconFlowProviderImplementation.dashboardURL(settings: fixture.settings, environment: env) == nil)
        let implementation = try #require(ProviderCatalog.implementation(for: .siliconflow))
        let fields = implementation.settingsFields(context: fixture.settingsContext(provider: .siliconflow))
        #expect(fields[0].actions.isEmpty)
    }
}

extension SiliconFlowProviderTests {
    @Test
    func `diagnostic messages have app translations`() {
        for message in SiliconFlowProviderDescriptor.diagnosticMessages {
            for language in AppLanguage.allCases where language != .system && language != .english {
                #expect(L(message, language: language.rawValue) != message)
            }
        }
        #expect(L("Show SiliconFlow usage", language: "de") == "Nutzung von SiliconFlow anzeigen")
    }
}

extension SiliconFlowProviderTests {
    @Test
    func `only explicit Web uses browser sessions and Auto keeps the API key`() async throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: "SiliconFlowSourceRouting")
        let implementation = try #require(ProviderCatalog.implementation(for: .siliconflow))
        let international = ["SILICONFLOW_BASE_URL": "https://api.siliconflow.com/v1"]
        #expect(!implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))
        fixture.settings.updateProviderConfig(provider: .siliconflow) { $0.source = .web }
        #expect(implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))
        fixture.settings.setCookieSource(.off, provider: .siliconflow)
        #expect(!implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))
        fixture.settings.setCookieSource(.auto, provider: .siliconflow)
        fixture.settings[providerConfig: .siliconflow, field: .apiKey] = "synthetic-key"
        #expect(!implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: international)))
        fixture.settings.setCookieSource(.off, provider: .siliconflow)
        #expect(!implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))
        fixture.settings.updateProviderConfig(provider: .siliconflow) { $0.source = .auto }
        #expect(implementation.isAvailable(context: .init(
            provider: .siliconflow, settings: fixture.settings, environment: [:])))

        let pipeline = SiliconFlowProviderDescriptor.descriptor.fetchPlan.pipeline
        func strategies(_ mode: ProviderSourceMode, _ env: [String: String]) async -> [String] {
            await pipeline.resolveStrategies(Self.context(mode, env)).map(\.id)
        }
        #expect(await strategies(.auto, [:]) == ["siliconflow.js"])
        #expect(await strategies(.web, [:]) == ["siliconflow.web"])
        #expect(await strategies(.api, [:]) == ["siliconflow.js"])
        #expect(await strategies(.auto, international) == ["siliconflow.js"])
        #expect(await strategies(.api, international) == ["siliconflow.js"])
        #expect(await strategies(.web, international).isEmpty)
    }

    @Test
    func `presentation reports the fetched source`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let context = fixture.presentationContext(
            provider: .siliconflow, metadata: SiliconFlowProviderDescriptor.descriptor.metadata)
        let presentation = SiliconFlowProviderImplementation().presentation(context: context)
        for source in ["api", "web"] {
            fixture.store.lastSourceLabels[.siliconflow] = source
            #expect(presentation.detailLine(context) == source)
        }
    }

    @Test
    func `Web picker changes the app fetch source and clears the previous authority`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        let implementation = SiliconFlowProviderImplementation()
        let context = fixture.settingsContext(provider: .siliconflow)
        let source = try #require(implementation.settingsPickers(context: context)
            .first { $0.id == "siliconflow-usage-source" })
        #expect(source.options.map(\.id) == ["auto", "api", "web"])
        fixture.store.lastSourceLabels[.siliconflow] = "api"
        source.binding.wrappedValue = "web"
        #expect(fixture.store.lastSourceLabels[.siliconflow] == nil)
        #expect(fixture.store.sourceMode(for: .siliconflow) == .web)
        #expect(fixture.store.sourceLabel(for: .siliconflow) == "web")
        #expect(implementation.settingsPickers(context: context).map(\.id) == [
            "siliconflow-usage-source", "siliconflow-cookie-source",
        ])
        #expect(implementation.settingsFields(context: context).first?.id == "siliconflow-cookie-header")
        fixture.store.lastSourceLabels[.siliconflow] = "web"
        source.binding.wrappedValue = "api"
        #expect(fixture.store.lastSourceLabels[.siliconflow] == nil)
        #expect(fixture.store.sourceMode(for: .siliconflow) == .api)
        source.binding.wrappedValue = "auto"
        #expect(fixture.store.sourceMode(for: .siliconflow) == .auto)
    }

    private static func context(_ mode: ProviderSourceMode, _ env: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: mode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection(cacheTTL: 0)),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}
