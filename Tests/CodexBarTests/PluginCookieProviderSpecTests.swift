import AppKit
import SweetCookieKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct PluginCookieProviderSpecTests {
    @Test
    func `render synthetic cookie guidance when requested`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_BROWSER_PROOF_DIR"] else { return }
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        fixture.settings.debugDisableKeychainAccess = false
        let implementation = try #require(ProviderCatalog.implementation(for: .museai))
        let picker = try #require(implementation.settingsPickers(
            context: fixture.settingsContext(provider: .museai)).first)
        let before = ProviderSettingsPickerDescriptor(
            id: picker.id,
            title: picker.title,
            subtitle: "Automatic imports Chrome cookies from muse.ai.",
            binding: picker.binding,
            options: picker.options,
            isVisible: nil,
            onChange: nil)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let runtime = try ProviderPluginCookieResultTests.missingSessionRuntime(engine: .quickJS, storage: storage)
        let message: String
        do {
            _ = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in nil })
            Issue.record("Expected missing session")
            return
        } catch {
            message = error.localizedDescription
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, descriptor, error) in [
            (
                "before",
                before,
                "No muse.ai session found. Sign in at muse.ai in Chrome, or set a manual Cookie header."),
            ("after", picker, message),
        ] {
            let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
                Text("Muse (muse.ai) · synthetic cookie settings").font(.headline).padding(.horizontal, 20)
                Form {
                    Section("Connection") { ProviderSettingsPickerRowView(picker: descriptor) }
                }.formStyle(.grouped).frame(height: 180)
                Text(error).font(.caption).padding(.horizontal, 20)
            }.frame(width: 620, height: 330).background(Color(nsColor: .windowBackgroundColor)))
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 330)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            defer { window.contentView = nil }
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("cookies-\(name).png"))
        }
    }

    @Test
    func `automatic cookie guidance names the provider browser policy and manual alternative`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        fixture.settings.debugDisableKeychainAccess = false
        for provider in [UsageProvider.museai, .raycast, .perplexity] {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let picker = try #require(implementation.settingsPickers(
                context: fixture.settingsContext(provider: provider)).first)
            let browsers = ProviderDefaults.metadata[provider]?.browserCookieOrder ?? Browser.defaultImportOrder
            let names = browsers.map(\.displayName).joined(separator: ", ")
            #expect(picker.subtitle.contains("Supported browsers: \(names). Use Manual for other browsers."))
            #expect(picker.dynamicSubtitle?()?.contains("Supported browsers: \(names).") == true)
            if provider == .museai {
                #expect(picker.subtitle.hasPrefix("Automatic imports browser cookies."))
                for name in ["Aside", "Opera", "Opera Neon"] {
                    #expect(browsers.map(\.displayName).contains(name))
                }
            }
        }
    }

    private static let providers: [UsageProvider] = [
        .helmcode, .hyper, .manus, .perplexity, .qoder, .raycast, .sakana, .t3chat, .lithosai,
    ]

    @Test
    func `cookie bindings preserve modes and keep headers separate from API keys`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        fixture.settings.debugDisableKeychainAccess = false
        for provider in Self.providers {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let context = fixture.settingsContext(provider: provider)
            let field = try #require(implementation.settingsFields(context: context).first)
            fixture.settings[providerConfig: provider, field: .apiKey] = "fixture-api-key"
            field.binding.wrappedValue = "session=fixture"
            #expect(fixture.settings[providerConfig: provider, field: .cookieHeader] == "session=fixture")
            #expect(fixture.settings[providerConfig: provider, field: .apiKey] == "fixture-api-key")
            #expect(field.kind == .secure)
            if provider == .sakana {
                #expect(implementation.settingsPickers(context: context).isEmpty)
                #expect(field.isVisible == nil)
                continue
            }
            let picker = try #require(implementation.settingsPickers(context: context).first)
            let allowsOff = ![UsageProvider.qoder, .t3chat].contains(provider)
            #expect(picker.options.map(\.id) == (allowsOff ? ["auto", "manual", "off"] : ["auto", "manual"]))
            for mode in [ProviderCookieSource.auto, .manual, .off] {
                picker.binding.wrappedValue = mode.rawValue
                #expect(fixture.settings.providerConfig(for: provider)?.cookieSource == mode)
                #expect(field.isVisible?() == (mode == .manual))
            }
            picker.binding.wrappedValue = "unknown"
            #expect(fixture.settings.providerConfig(for: provider)?.cookieSource == .auto)
            fixture.settings.debugDisableKeychainAccess = true
            let disabled = try #require(implementation.settingsPickers(context: context).first)
            #expect(!disabled.options.contains { $0.id == "auto" })
            fixture.settings.debugDisableKeychainAccess = false
        }
    }

    @Test
    func `session accounts select manual cookies but Hyper API accounts do not`() throws {
        let fixture = try ProviderSettingsDescriptorTests().makeSettingsFixture(suite: #function)
        for provider in [UsageProvider.manus, .qoder, .hyper] {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let support = try #require(TokenAccountSupportCatalog.support(for: provider))
            let context = fixture.settingsContext(provider: provider)
            fixture.settings.setCookieSource(.auto, provider: provider)
            #expect(implementation.tokenAccountsVisibility(context: context, support: support) == (provider == .hyper))
            implementation.applyTokenAccountCookieSource(settings: fixture.settings)
            #expect(fixture.settings.resolvedCookieSource(provider: provider, fallback: .auto) ==
                (provider == .hyper ? .auto : .manual))
            #expect(implementation.tokenAccountsVisibility(context: context, support: support))
        }
        #expect(RaycastProviderDescriptor.descriptor.credentials == nil)
        #expect(T3ChatProviderDescriptor.descriptor.credentials == nil)
    }

    @Test
    func `hybrid fetch kind follows the requested source without requiring a key`() async throws {
        let descriptor = HyperProviderDescriptor.descriptor
        for source in [ProviderSourceMode.auto, .web, .api] {
            let context = self.context(source: source)
            let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
            let strategy = try #require(strategies.first)
            #expect(strategy.id == "hyper.js")
            #expect(strategy.kind == (source == .web ? .web : .apiToken))
            #expect(await strategy.isAvailable(context))
        }
        for provider in Self.providers where provider != .hyper {
            #expect(ProviderDescriptorRegistry.descriptor(for: provider).fetchPlan.sourceModes == [.auto, .web])
        }
    }

    @Test
    func `web watchdog budgets preserve request headroom and nonfinite policies`() throws {
        let raycast = try #require(RaycastProviderDescriptor.spec.webSource)
        let t3 = try #require(T3ChatProviderDescriptor.spec.webSource)
        let sakana = try #require(SakanaProviderDescriptor.spec.webSource)
        let cases: [(TimeInterval, TimeInterval, TimeInterval, TimeInterval)] = [
            (-1, 30, 20, 20), (15, 30, 20, 20), (60, 60, 65, 61), (200, 200, 95, 91),
            (.infinity, 30, 95, 20), (-.infinity, 30, 20, 20), (.nan, 30, 95, 20),
        ]
        for (input, raycastBudget, t3Budget, sakanaBudget) in cases {
            let context = self.context(timeout: input)
            #expect(raycast.timeout.resolve(context) == raycastBudget)
            #expect(t3.timeout.resolve(context) == t3Budget)
            #expect(sakana.timeout.resolve(context) == sakanaBudget)
        }
    }

    private func context(source: ProviderSourceMode = .auto, timeout: TimeInterval = 15) -> ProviderFetchContext {
        let base = ProviderCutoverTestSupport.context()
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: source,
            includeCredits: false,
            webTimeout: timeout,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: base.fetcher,
            claudeFetcher: base.claudeFetcher,
            browserDetection: base.browserDetection)
    }
}
