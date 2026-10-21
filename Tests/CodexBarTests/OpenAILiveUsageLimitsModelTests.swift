import AppKit
import CodexBarCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct OpenAILiveUsageLimitsModelTests {
    @Test
    func `rebuilt settings limits bindings use the selected credential without inheritance`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = self.context(settings: settings, store: store)
        var binding = context.modelRateLimitsBinding(scope: settings.modelRateLimitScope(for: .openai))
        let provider: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 100)]
        let a: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 200)]
        let b: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 300)]
        #expect(settings.modelRateLimitScope(for: .openai) == .provider)
        binding.wrappedValue = provider
        #expect(binding.wrappedValue == provider)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits == provider)
        #expect(OpenAIAPIProviderImplementation().settingsModelLimits(context: context).first?.scopeText == nil)
        settings.addTokenAccount(provider: .openai, label: "A", token: "synthetic-a")
        let accountA = try #require(settings.selectedTokenAccount(for: .openai))
        binding = context.modelRateLimitsBinding(scope: settings.modelRateLimitScope(for: .openai))
        #expect(binding.wrappedValue.isEmpty)
        binding.wrappedValue = a
        settings.addTokenAccount(provider: .openai, label: "B", token: "synthetic-b")
        let accountB = try #require(settings.selectedTokenAccount(for: .openai))
        binding = context.modelRateLimitsBinding(scope: settings.modelRateLimitScope(for: .openai))
        #expect(binding.wrappedValue.isEmpty)
        binding.wrappedValue = b
        #expect(settings.modelRateLimitScope(for: .openai) == .tokenAccount(accountB.id))
        #expect(OpenAIAPIProviderImplementation().settingsModelLimits(context: context).first?.scopeText ==
            L("Applies to the selected token account “%@”. Each account keeps its own limits.", "B"))
        settings.setActiveTokenAccountIndex(0, for: .openai)
        binding = context.modelRateLimitsBinding(scope: settings.modelRateLimitScope(for: .openai))
        #expect(settings.modelRateLimitScope(for: .openai) == .tokenAccount(accountA.id))
        #expect(binding.wrappedValue == a)
        let edited: [ProviderModelRateLimit] = [.init(model: " gpt-5 ", tokensPerMinute: 400, requestsPerMinute: 0)]
        binding.wrappedValue = edited
        #expect(binding.wrappedValue == ProviderModelRateLimit.validated(edited))
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits == provider)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(accountB.id)) == b)
        settings.updateTokenAccount(provider: .openai, accountID: accountA.id, label: "Renamed A")
        #expect(binding.wrappedValue == ProviderModelRateLimit.validated(edited))
        binding.wrappedValue = []
        #expect(binding.wrappedValue.isEmpty)
        let cleared = try #require(settings.providerConfig(for: .openai)?.tokenAccounts?.accounts
            .first(where: { $0.id == accountA.id }))
        #expect(cleared.modelRateLimits == [])
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits == provider)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(accountB.id)) == b)
        settings.setActiveTokenAccountIndex(1, for: .openai)
        binding = context.modelRateLimitsBinding(scope: settings.modelRateLimitScope(for: .openai))
        #expect(binding.wrappedValue == b)
        settings.removeTokenAccount(provider: .openai, accountID: accountA.id)
        settings.removeTokenAccount(provider: .openai, accountID: accountB.id)
        binding = context.modelRateLimitsBinding(scope: settings.modelRateLimitScope(for: .openai))
        #expect(binding.wrappedValue == provider)
        binding.wrappedValue = []
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits?.isEmpty != false)
    }

    @Test
    func `settings limit descriptors keep their captured credential after selection changes`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = self.context(settings: settings, store: store)
        let implementation = OpenAIAPIProviderImplementation()
        let provider: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 100)]
        let saved: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 200)]
        settings.addTokenAccount(provider: .openai, label: "A", token: "synthetic-a")
        let accountA = try #require(settings.selectedTokenAccount(for: .openai))
        settings.addTokenAccount(provider: .openai, label: "B", token: "synthetic-b")
        let accountB = try #require(settings.selectedTokenAccount(for: .openai))
        settings.updateProviderConfig(provider: .openai, affectsBackgroundWork: false) {
            $0.setModelRateLimits(provider, for: .provider)
            $0.setModelRateLimits(saved, for: .tokenAccount(accountA.id))
            $0.setModelRateLimits(saved, for: .tokenAccount(accountB.id))
        }
        settings.setActiveTokenAccountIndex(0, for: .openai)
        let descriptorA = try #require(implementation.settingsModelLimits(context: context).first)
        #expect(descriptorA.scope == .tokenAccount(accountA.id))
        #expect(descriptorA.binding.wrappedValue == saved)
        settings.setActiveTokenAccountIndex(1, for: .openai)
        #expect(descriptorA.binding.wrappedValue == saved)
        let editedA: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 300)]
        descriptorA.binding.wrappedValue = editedA
        #expect(descriptorA.binding.wrappedValue == editedA)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(accountA.id)) == editedA)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(accountB.id)) == saved)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits == provider)
        let descriptorB = try #require(implementation.settingsModelLimits(context: context).first)
        #expect(descriptorB.scope == .tokenAccount(accountB.id))
        #expect(descriptorB.binding.wrappedValue == saved)
        let editedB: [ProviderModelRateLimit] = [.init(model: "gpt-5", tokensPerMinute: 400)]
        descriptorB.binding.wrappedValue = editedB
        #expect(descriptorB.binding.wrappedValue == editedB)
        #expect(descriptorA.binding.wrappedValue == editedA)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(accountA.id)) == editedA)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits(for: .tokenAccount(accountB.id)) == editedB)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits == provider)
    }

    @Test
    func `displayed limits stay with the captured account until refresh and observe edits`() async throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.addTokenAccount(provider: .openai, label: "A", token: "synthetic-a")
        let a = try #require(settings.selectedTokenAccount(for: .openai))
        settings.addTokenAccount(provider: .openai, label: "B", token: "synthetic-b")
        let b = try #require(settings.selectedTokenAccount(for: .openai))
        settings.updateProviderConfig(provider: .openai, affectsBackgroundWork: false) {
            $0.setModelRateLimits([.init(model: "gpt-5", tokensPerMinute: 200)], for: .tokenAccount(a.id))
            $0.setModelRateLimits([.init(model: "gpt-5", tokensPerMinute: 300)], for: .tokenAccount(b.id))
        }
        settings.setActiveTokenAccountIndex(0, for: .openai)
        let model = OpenAILiveUsageModel(
            environment: {
                ProviderRegistry.makeEnvironment(base: [:], provider: .openai, settings: settings, tokenOverride: nil)
            },
            limitScope: { settings.modelRateLimitScope(for: .openai) },
            manualLimits: { scope in settings.providerConfig(for: .openai)?.modelRateLimits(for: scope) ?? [] },
            fetchLimits: { _ in .init(byModel: [:], projectsSampled: 0, truncated: false, fetchedAt: Date()) },
            fetch: { _, minutes in .init(minutes: [], windowMinutes: minutes, fetchedAt: Date(), projectID: nil) })
        model.start()
        defer { model.stop() }
        await model.waitForRefresh()
        await model.waitForLimitsRefresh()
        #expect(model.displayedLimitScope == .tokenAccount(a.id))
        #expect(model.limits.resolve("gpt-5")?.tokensPerMinute == 200)
        let snapshot = model.snapshot
        settings.setActiveTokenAccountIndex(1, for: .openai)
        #expect(model.snapshot?.fetchedAt == snapshot?.fetchedAt)
        #expect(model.displayedLimitScope == .tokenAccount(a.id))
        #expect(model.limits.resolve("gpt-5")?.tokensPerMinute == 200)
        let changed = LockIsolated(false)
        withObservationTracking {
            _ = model.limits
        } onChange: {
            changed.setValue(true)
        }
        settings.updateProviderConfig(provider: .openai, affectsBackgroundWork: false) {
            $0.setModelRateLimits([.init(model: "gpt-5", tokensPerMinute: 250)], for: .tokenAccount(a.id))
        }
        #expect(changed.value)
        #expect(model.limits.resolve("gpt-5")?.tokensPerMinute == 250)
        model.refresh()
        await model.waitForRefresh()
        await model.waitForLimitsRefresh()
        #expect(model.snapshot != nil)
        #expect(model.displayedLimitScope == .tokenAccount(b.id))
        #expect(model.limits.resolve("gpt-5")?.tokensPerMinute == 300)
    }

    @Test
    func `account limits do not change snapshot cache keys and selected tokens own the environment`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.updateProviderConfig(provider: .openai) {
            $0.apiKey = "synthetic-config"
            $0.workspaceID = "proj_synthetic"
        }
        settings.addTokenAccount(provider: .openai, label: "A", token: "synthetic-selected")
        let account = try #require(settings.selectedTokenAccount(for: .openai))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let key = store.tokenAccountSnapshotCacheKey(provider: .openai, account: account)
        let edited = account.withModelRateLimits([.init(model: "gpt-5", tokensPerMinute: 100)])
        settings.updateProviderConfig(provider: .openai, affectsBackgroundWork: false) {
            $0.setModelRateLimits(edited.modelRateLimits ?? [], for: .tokenAccount(account.id))
        }
        #expect(store.tokenAccountSnapshotCacheKey(provider: .openai, account: edited) == key)
        let environment = ProviderRegistry.makeEnvironment(
            base: [
                "OPENAI_ADMIN_KEY": "synthetic-env-admin",
                "OPENAI_API_KEY": "synthetic-env-api",
                "OPENAI_PROJECT_ID": "proj_environment",
            ],
            provider: .openai,
            settings: settings,
            tokenOverride: nil)
        #expect(OpenAIAPISettingsReader.apiKey(environment: environment) == account.token)
        #expect(OpenAIAPISettingsReader.adminAPIKey(environment: environment) == account.token)
        #expect(environment["OPENAI_PROJECT_ID"] == nil)
    }

    private func context(settings: SettingsStore, store: UsageStore) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: .openai,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
    }

    @Test
    func `limits cadence distinguishes polling manual refresh and first open`() {
        let now = Date()
        #expect(OpenAILiveUsageLimitsPolicy.shouldFetch(lastAttempt: nil, now: now, manual: false))
        for manual in [false, true] {
            #expect(!OpenAILiveUsageLimitsPolicy.shouldFetch(lastAttempt: now, now: now, manual: manual))
            #expect(!OpenAILiveUsageLimitsPolicy.shouldFetch(
                lastAttempt: now.addingTimeInterval(-300), now: now, manual: manual))
        }
        #expect(OpenAILiveUsageLimitsPolicy.shouldFetch(
            lastAttempt: now.addingTimeInterval(-301), now: now, manual: true))
        #expect(!OpenAILiveUsageLimitsPolicy.shouldFetch(
            lastAttempt: now.addingTimeInterval(-899), now: now, manual: false))
        #expect(OpenAILiveUsageLimitsPolicy.shouldFetch(
            lastAttempt: now.addingTimeInterval(-900), now: now, manual: false))
    }

    @Test
    func `limit rule stays near plotted bars including the exact boundary`() {
        #expect(OpenAILiveUsageLimitsPolicy.showsRule(limit: 150, peak: 100))
        #expect(!OpenAILiveUsageLimitsPolicy.showsRule(limit: 151, peak: 100))
        #expect(!OpenAILiveUsageLimitsPolicy.showsRule(limit: 1, peak: 0))
        #expect(!OpenAILiveUsageLimitsPolicy.showsRule(limit: 0, peak: 100))

        // A large partial bucket in the in-progress minute must not decide whether the rule fits.
        let now = Date(timeIntervalSince1970: 120_025)
        let snapshot = OpenAILiveUsageSnapshot(
            minutes: [
                .init(start: now.addingTimeInterval(-90), models: [
                    .init(name: "a", inputTokens: 20, cachedInputTokens: 0, outputTokens: 0, requests: 1),
                ]),
                .init(start: now.addingTimeInterval(-30), models: [
                    .init(name: "a", inputTokens: 900, cachedInputTokens: 0, outputTokens: 0, requests: 1),
                ]),
            ],
            windowMinutes: 15,
            fetchedAt: now,
            projectID: nil)
        let points = snapshot.series(for: .model("a"))
        #expect(points.last?.isPending == true)
        #expect(!OpenAILiveUsageLimitsPolicy.showsRule(limit: 100, points: points))
        #expect(OpenAILiveUsageLimitsPolicy.showsRule(limit: 30, points: points))
    }

    @Test
    func `limit rule uses plotted totals even when most traffic is batch`() {
        let now = Date(timeIntervalSince1970: 120_025)
        let snapshot = OpenAILiveUsageSnapshot(
            minutes: [
                .init(start: Date(timeIntervalSince1970: 119_940), models: [
                    .init(
                        name: "model-fixture",
                        inputTokens: 100,
                        cachedInputTokens: 60,
                        outputTokens: 0,
                        requests: 10,
                        batchTokens: 90,
                        batchRequests: 9),
                ]),
            ],
            windowMinutes: 15,
            fetchedAt: now,
            projectID: nil)
        let points = snapshot.series(for: .allModels)
        #expect(points.first?.limitCountedTokens == 10)
        #expect(OpenAILiveUsageLimitsPolicy.showsRule(limit: 150, points: points))
        #expect(!OpenAILiveUsageLimitsPolicy.showsRule(limit: 151, points: points))
    }

    @Test
    func `batch caption renders a literal percent in every locale`() {
        for language in [
            "ar",
            "ca",
            "de",
            "en",
            "es",
            "fa",
            "fr",
            "gl",
            "id",
            "it",
            "ja",
            "ko",
            "nl",
            "pl",
            "pt-BR",
            "ru",
            "sv",
            "th",
            "tr",
            "uk",
            "vi",
            "zh-Hans",
            "zh-Hant",
        ] {
            CodexBarLocalizationOverride.$appLanguage.withValue(language) {
                let text = L("Batch API %@ · not counted in %% of limit", "123")
                #expect(text.contains("Batch API"))
                #expect(text.contains("123"))
                #expect(text.contains("%"))
                #expect(!text.contains("%%"))
                #expect(!text.contains("%@"))
                if language == "en" {
                    #expect(text == "Batch API 123 · not counted in % of limit")
                }
            }
        }
    }

    @Test
    func `limits failures preserve usage polling and cached manual limits`() async {
        let source = Source()
        var now = Date()
        let model = OpenAILiveUsageModel(
            environment: { [:] },
            manualLimits: { _ in [.init(model: "gpt-5", tokensPerMinute: 100)] },
            now: { now },
            fetchLimits: { _ in try await source.fetch() },
            fetch: { _, minutes in .init(minutes: [], windowMinutes: minutes, fetchedAt: Date(), projectID: nil) })
        model.start()
        await model.waitForRefresh()
        await model.waitForLimitsRefresh()
        let snapshot = model.snapshot
        #expect(model.projectCaps != nil)
        await source.fail()
        now = now.addingTimeInterval(301)
        model.refresh()
        await model.waitForRefresh()
        await model.waitForLimitsRefresh()
        #expect(model.snapshot?.minutes == snapshot?.minutes)
        #expect(model.lastError == nil)
        #expect(model.pollingInterval == 30)
        #expect(model.limitsError != nil)
        #expect(model.projectCaps != nil)
        #expect(model.limits.resolve("gpt-5")?.tokensPerMinute == 100)
        #expect(await source.calls == 2)
        model.refresh()
        await model.waitForRefresh()
        #expect(await source.calls == 2)
        model.stop()
    }

    @Test
    func `OpenAI contributes generic settings limits and edits are observed immediately`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .openai,
            settings: settings,
            store: store,
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let descriptor = try #require(OpenAIAPIProviderImplementation().settingsModelLimits(context: context).first)
        #expect(descriptor.title == "Organization rate limits")
        #expect(descriptor.actions.count == 1)
        #expect(descriptor.binding.wrappedValue.isEmpty)
        let model = OpenAILiveUsageModel(environment: { [:] }, manualLimits: { _ in
            settings.providerConfig(for: .openai)?.modelRateLimits ?? []
        })
        #expect(model.limits.resolve("gpt-5") == nil)
        let values = [ProviderModelRateLimit(model: "gpt-5", tokensPerMinute: 40_000_000, requestsPerMinute: 15000)]
        let changed = LockIsolated(false)
        withObservationTracking {
            _ = model.limits
        } onChange: {
            changed.setValue(true)
        }
        descriptor.binding.wrappedValue = values
        #expect(changed.value)
        #expect(settings.providerConfig(for: .openai)?.modelRateLimits == values)
        #expect(model.limits.resolve("gpt-5-2025-08-07")?.tokensPerMinute == 40_000_000)
        descriptor.binding.wrappedValue = []
        #expect(model.limits.resolve("gpt-5") == nil)
    }

    @Test
    func `editor drafts reject invalid entries and preserve optional RPM`() {
        var draft = ProviderModelLimitDraft()
        #expect(draft.value == nil)
        draft.model = " gpt-5 "
        draft.tpm = "40M"
        #expect(draft.value == .init(model: "gpt-5", tokensPerMinute: 40_000_000))
        draft.rpm = "bad"
        #expect(draft.value == nil)
        draft.rpm = "15k"
        #expect(draft.value?.requestsPerMinute == 15000)
        #expect(ProviderModelLimitDraft(limit: draft.value).tpm == "40M")
    }

    @Test
    func `updated age uses minutes and hours at their exact boundaries`() {
        let date = Date(timeIntervalSince1970: 120_000)
        for (seconds, expected) in [
            (0, L("Updated just now")), (59, L("Updated just now")),
            (60, L("Updated %@m ago", "1")), (259, L("Updated %@m ago", "4")),
            (3599, L("Updated %@m ago", "59")), (3600, L("Updated %@h ago", "1")),
            (90000, L("Updated %@h ago", "25")),
        ] {
            #expect(OpenAILiveUsageView
                .updatedText(from: date, now: date.addingTimeInterval(Double(seconds))) == expected)
        }
    }

    @Test
    func `large token counts use compact units without scientific notation`() {
        #expect(OpenAILiveUsageView.count(50_000_000) == "50M")
        #expect(OpenAILiveUsageView.count(100_000_000) == "100M")
        #expect(OpenAILiveUsageView.count(1_500_000_000) == "1.5B")
    }

    @Test
    func `render synthetic limits views when requested`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_OPENAI_LIMITS_PROOF"] else { return }
        let date = Date(timeIntervalSince1970: floor((Date().timeIntervalSince1970 - 240) / 60) * 60)
        let manual = [ProviderModelRateLimit(model: "gpt-5", tokensPerMinute: 80_000_000, requestsPerMinute: 100)]
        let model = OpenAILiveUsageModel(
            environment: { [:] },
            manualLimits: { _ in manual },
            fetchLimits: { _ in .init(
                byModel: [
                    "gpt-4o": .init(tokensPerMinute: 40_000_000, requestsPerMinute: 200),
                    "gpt-5": .init(tokensPerMinute: 40_000_000),
                ],
                projectsSampled: 25,
                truncated: true,
                fetchedAt: date) },
            fetch: { _, _ in .init(
                minutes: (0..<60).map { index in .init(
                    start: date.addingTimeInterval(Double(index - 59) * 60),
                    models: index >= 57 ? [] : [
                        .init(
                            name: "gpt-5-2025-08-07",
                            inputTokens: 25_000_000 + index * 500_000,
                            cachedInputTokens: 10_000_000,
                            outputTokens: 10_000_000,
                            requests: 70),
                        .init(
                            name: "gpt-4o",
                            inputTokens: index == 50 ? 87_000_000 : 65_000_000,
                            cachedInputTokens: 0,
                            outputTokens: 10_000_000,
                            requests: 20),
                    ]) },
                windowMinutes: 60,
                fetchedAt: date,
                projectID: "proj_synthetic") })
        model.start()
        await model.waitForRefresh()
        await model.waitForLimitsRefresh()
        defer { model.stop() }
        for (name, filter) in [
            ("all", OpenAILiveUsageModelFilter.allModels),
            ("manual-limit", .model("gpt-5-2025-08-07")),
            ("project-cap-only", .model("gpt-4o")),
        ] {
            model.filter = filter
            try Self.render(
                OpenAILiveUsageView(model: model, openSettings: {}),
                size: NSSize(width: 1040, height: 740),
                to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        #expect(model.snapshot?.summary(for: .model("gpt-4o")).latestTPM == 75_000_000)
        #expect(model.snapshot?.summary(for: .model("gpt-4o")).peakTPM == 97_000_000)
        #expect(model.snapshot?.utilization(for: .model("gpt-4o"), limits: model.limits) == nil)
        let descriptor = ProviderSettingsModelLimitsDescriptor(
            id: "synthetic",
            title: "Organization rate limits",
            subtitle: "OpenAI's API doesn't expose organization rate limits. Copy them from your organization's " +
                "Limits page. Model IDs match dated snapshots (gpt-5 covers gpt-5-2025-…).",
            binding: .constant(manual),
            actions: [])
        try Self.render(
            Form { ProviderSettingsModelLimitsRowView(descriptor: descriptor) }.formStyle(.grouped),
            size: NSSize(width: 700, height: 250),
            to: URL(fileURLWithPath: directory).appendingPathComponent("settings.png"))
        var scoped = descriptor
        scoped.scopeText = L(
            "Applies to the selected token account “%@”. Each account keeps its own limits.",
            "Synthetic Org B")
        try Self.render(
            Form { ProviderSettingsModelLimitsRowView(descriptor: scoped) }.formStyle(.grouped),
            size: NSSize(width: 700, height: 270),
            to: URL(fileURLWithPath: directory).appendingPathComponent("settings-account-scope.png"))
    }

    private static func render(_ view: some View, size: NSSize, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private actor Source {
        var calls = 0
        var shouldFail = false

        func fail() { self.shouldFail = true }

        func fetch() throws -> OpenAIOrgRateLimits {
            self.calls += 1
            if self.shouldFail { throw OpenAIOrgRateLimitsError.rateLimited }
            return .init(byModel: [:], projectsSampled: 1, truncated: false, fetchedAt: Date())
        }
    }
}
