#if canImport(JavaScriptCore)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct UserPluginRefreshTests {
    enum Change: CaseIterable {
        case disable, disableAndReenable, setting, settingAndRestore, secret, reload, remove
    }

    @Test(arguments: Change.allCases, [false, true])
    func `obsolete plugin results and errors cannot publish`(change: Change, failure: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = Self.capture(.usageUpdated, fixture: fixture)
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)

        switch change {
        case .disable:
            fixture.settings.setPluginEnabled(fixture.id, enabled: false)
            fixture.store.clearDisabledProviderState(enabledProviders: Set(UsageProvider.allCases.map(\.instanceID)))
        case .disableAndReenable:
            fixture.settings.setPluginEnabled(fixture.id, enabled: false)
            fixture.settings.setPluginEnabled(fixture.id, enabled: true)
        case .setting:
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "second"] }
        case .settingAndRestore:
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "second"] }
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "first"] }
        case .secret:
            fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSecrets = ["TOKEN": "new-fixture"] }
        case .reload:
            fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        case .remove:
            try FileManager.default.removeItem(at: fixture.pluginURL)
            fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        }

        await fixture.transport.finish(1, used: 42, failure: failure)
        await request.value
        #expect(fixture.store.snapshots[fixture.id] == nil)
        #expect(fixture.store.errors[fixture.id] == nil)
        #expect(fixture.store.lastSourceLabels[fixture.id] == nil)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        #expect(fixture.store.sessionLimitResetDetectorStates.isEmpty)
        #expect(fixture.store.weeklyLimitResetDetectorStates.isEmpty)
    }

    @Test
    func `replacement waits for retired work and uses configuration at fetch start`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        var replacementEntered = false
        let replacement = Task {
            replacementEntered = true
            await fixture.store.refreshUserPlugin(fixture.id)
        }
        while !replacementEntered {
            await Task.yield()
        }
        fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "after-queue"] }

        await fixture.transport.finish(1, used: 10)
        await first.value
        try await fixture.transport.waitForRequests(2)
        #expect(fixture.store.snapshots[fixture.id] == nil)
        #expect(fixture.store.refreshingProviders.contains(fixture.id))
        #expect(await fixture.transport.request(2)?.url?.query == "account=after-queue")

        await fixture.transport.finish(2, used: 80)
        await replacement.value
        #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == 80)
        #expect(fixture.store.errors[fixture.id] == nil)
        #expect(fixture.store.lastSourceLabels[fixture.id] == "js")
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @Test
    func `reenabled plugin owns activity while its replacement waits`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        fixture.settings.setPluginEnabled(fixture.id, enabled: false)
        fixture.store.clearDisabledProviderState(enabledProviders: Set(UsageProvider.allCases.map(\.instanceID)))
        fixture.settings.setPluginEnabled(fixture.id, enabled: true)
        var replacementEntered = false
        let replacement = Task {
            replacementEntered = true
            await fixture.store.refreshUserPlugin(fixture.id)
        }
        while !replacementEntered {
            await Task.yield()
        }
        #expect(fixture.store.refreshingProviders.contains(fixture.id))
        await fixture.transport.finish(1, used: 10)
        await first.value
        #expect(fixture.store.refreshingProviders.contains(fixture.id))
        try await fixture.transport.waitForRequests(2)
        await fixture.transport.finish(2, used: 80)
        await replacement.value
        #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == 80)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
    }

    @Test
    func `cancelled plugin refresh does not publish a failure`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = Self.capture(.usageUpdated, fixture: fixture)
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        request.cancel()
        await fixture.transport.finish(1, used: 42, failure: true)
        await request.value
        #expect(fixture.store.snapshots[fixture.id] == nil)
        #expect(fixture.store.errors[fixture.id] == nil)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        #expect(fixture.store.sessionLimitResetDetectorStates.isEmpty)
        #expect(fixture.store.weeklyLimitResetDetectorStates.isEmpty)
    }

    @Test
    func `display preference changes keep a valid plugin response publishable`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.accentColor = "#FF0000" }
        await fixture.transport.finish(1, used: 42)
        await request.value
        #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == 42)
    }

    @Test
    func `current plugin failures remain visible`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = Self.capture(.usageUpdated, fixture: fixture)
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        await fixture.transport.finish(1, used: 42, failure: true)
        await request.value
        #expect(fixture.store.errors[fixture.id] != nil)
        #expect(!fixture.store.refreshingProviders.contains(fixture.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        #expect(fixture.store.sessionLimitResetDetectorStates.isEmpty)
        #expect(fixture.store.weeklyLimitResetDetectorStates.isEmpty)
    }

    @Test
    func `cached plugin card shows refresh failure and clears it after recovery`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plugin = try #require(UserProviderPluginRegistry.plugin(for: fixture.id))
        var lastGood: Int?
        var successHeight: CGFloat?
        var failureOnlyHeight: CGFloat?
        for (index, used, failure) in [(1, 42, true), (2, 42, false), (3, 42, true), (4, 65, false)] {
            let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
            try await fixture.transport.waitForRequests(index)
            await fixture.transport.finish(index, used: used, failure: failure)
            await request.value
            if !failure { lastGood = used }
            #expect(fixture.store.snapshots[fixture.id]?.primary?.usedPercent == lastGood.map(Double.init))
            let view = NSHostingView(rootView: UserPluginMenuCardView(
                plugin: plugin,
                snapshot: fixture.store.snapshots[fixture.id],
                error: fixture.store.errors[fixture.id],
                isRefreshing: false,
                showUsed: true,
                resetStyle: .countdown,
                width: 330,
                onRefresh: {}))
            let height = view.fittingSize.height
            #expect(height > 0)
            if failure {
                #expect(fixture.store.errors[fixture.id] != nil)
                if lastGood != nil {
                    let usageOnly = try #require(successHeight)
                    let errorOnly = try #require(failureOnlyHeight)
                    // Both sections must contribute layout; retaining data or an error in the store alone is not
                    // enough.
                    #expect(height > usageOnly)
                    #expect(height > errorOnly)
                    let error = try #require(fixture.store.errors[fixture.id])
                    let errorHeight = NSHostingView(rootView: Text(error).font(.caption)
                        .frame(width: 330 - 2 * UsageMenuCardLayout.horizontalPadding)).fittingSize.height
                    // The capture-age line must add layout beyond the error and its stack spacing.
                    #expect(height > usageOnly + errorHeight + 9)
                } else {
                    failureOnlyHeight = height
                }
            } else {
                #expect(fixture.store.errors[fixture.id] == nil)
                if let successHeight { #expect(abs(height - successHeight) < 0.5) }
                successHeight = height
            }
        }
    }

    @Test
    func `retained plugin fingerprint includes capture age and app language`() {
        let now = Date(timeIntervalSinceReferenceDate: 805_000_000)
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, updatedAt: now.addingTimeInterval(-600))
        let error = "Fixture endpoint offline."
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            let fingerprint = UserPluginMenuCardView.fingerprint(
                snapshot: snapshot, error: error, resetStyle: .countdown, now: now)
            #expect(fingerprint.contains(LastKnownUsagePresentation.message(capturedAt: snapshot.updatedAt, now: now)))
            #expect(fingerprint.hasPrefix(codexBarLocalizationSignature() + "|"))
            return fingerprint
        }
        let german = CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            let fingerprint = UserPluginMenuCardView.fingerprint(
                snapshot: snapshot, error: error, resetStyle: .countdown, now: now)
            #expect(fingerprint.contains(LastKnownUsagePresentation.message(capturedAt: snapshot.updatedAt, now: now)))
            #expect(fingerprint.hasPrefix(codexBarLocalizationSignature() + "|"))
            return fingerprint
        }
        #expect(english != german)
        let later = now.addingTimeInterval(3600)
        let aged = UserPluginMenuCardView.fingerprint(
            snapshot: snapshot, error: error, resetStyle: .countdown, now: later)
        #expect(aged != english)
        #expect(aged.contains(LastKnownUsagePresentation.message(capturedAt: snapshot.updatedAt, now: later)))
        let recovered = UserPluginMenuCardView.fingerprint(
            snapshot: snapshot, error: nil, resetStyle: .countdown, now: now)
        #expect(recovered == UserPluginMenuCardView.fingerprint(
            snapshot: snapshot, error: nil, resetStyle: .countdown, now: later))
        #expect(!recovered.contains(LastKnownUsagePresentation.message(capturedAt: snapshot.updatedAt, now: now)))
        #expect(UserPluginMenuCardView.fingerprint(snapshot: nil, error: error, resetStyle: .countdown, now: now) ==
            UserPluginMenuCardView.fingerprint(snapshot: nil, error: error, resetStyle: .countdown, now: later))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let pluginURL: URL
        let loader: UserProviderPluginLoader
        let transport = GatedTransport()
        let settings: SettingsStore
        let store: UsageStore
        let id: ProviderInstanceID

        init() throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let providers = self.root.appendingPathComponent("providers")
            try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
            self.pluginURL = providers.appendingPathComponent("refresh.js")
            try Data("""
            defineProvider({
              id: "refresh-fixture", name: "Refresh Fixture",
              endpoints: ["https://usage.example"],
              settings: [{key:"ACCOUNT",title:"Account",type:"plain"},{key:"TOKEN",title:"Token",type:"secure"}],
              async fetchUsage(ctx) {
                const result = await ctx.http.getJSON("https://usage.example/usage?account=" +
                  encodeURIComponent(ctx.settings.get("ACCOUNT")));
                return {
                  primary:{usedPercent:result.json.used,windowMinutes:300},
                  secondary:{usedPercent:result.json.used + 10,windowMinutes:10080},
                  identity:{email:"fixture@example.test"}
                };
              }
            });
            """.utf8).write(to: self.pluginURL)
            self.loader = UserProviderPluginLoader(
                providersDirectory: providers,
                cacheDirectory: self.root.appendingPathComponent("cache"),
                transport: self.transport)
            let plugin = try #require(UserProviderPluginRegistry.refresh(loader: self.loader).first?.plugin)
            self.id = plugin.manifest.id
            let approvals = ProviderPluginApprovalStore(fileURL: self.root.appendingPathComponent("approvals.json"))
            try approvals.record(plugin.approvalBinding(settings: ["ACCOUNT": "first"]))
            self.settings = testSettingsStore(
                suiteName: "UserPluginRefreshTests",
                userDefaults: InMemoryUserDefaults())
            self.settings.refreshFrequency = .manual
            self.settings.statusChecksEnabled = false
            self.settings.updatePluginConfig(instanceID: self.id) {
                $0.enabled = true
                $0.pluginSettings = ["ACCOUNT": "first"]
                $0.pluginSecrets = ["TOKEN": "fixture"]
            }
            self.store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: self.settings,
                startupBehavior: .testing,
                environmentBase: [:],
                pluginApprovalStore: approvals)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
            UserProviderPluginRegistry.refresh(loader: self.loader)
        }
    }

    private actor GatedTransport: ProviderHTTPTransport {
        private var requests: [URLRequest] = []
        private var continuations: [Int: CheckedContinuation<(Data, URLResponse), any Error>] = [:]

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            self.requests.append(request)
            let index = self.requests.count
            return try await withCheckedThrowingContinuation { self.continuations[index] = $0 }
        }

        func request(_ index: Int) -> URLRequest? {
            self.requests.indices.contains(index - 1) ? self.requests[index - 1] : nil
        }

        func waitForRequests(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while self.requests.count < count, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(self.requests.count >= count)
        }

        func finish(_ index: Int, used: Int, failure: Bool = false) {
            guard let continuation = self.continuations.removeValue(forKey: index),
                  let url = self.request(index)?.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: failure ? 401 : 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"])
            else { return }
            continuation.resume(returning: (Data("{\"used\":\(used)}".utf8), response))
        }
    }
}

extension UserPluginRefreshTests {
    @Test(arguments: [false, true])
    func `successful publication reaches specific and any provider hooks with private fractional payloads`(
        hidePersonalInfo: Bool) async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.settings.hidePersonalInfo = hidePersonalInfo
        let specific = Self.capture(.usageUpdated, fixture: fixture, provider: fixture.id.rawValue)
        let any = Self.capture(.usageUpdated, fixture: fixture)
        let request = Task { await fixture.store.refreshUserPlugin(fixture.id) }
        try await fixture.transport.waitForRequests(1)
        await fixture.transport.finish(1, used: 42)
        await request.value
        for output in [specific, any] {
            let payload = try await Self.payload(at: output)
            #expect(payload["event"] as? String == "usage_updated")
            #expect(payload["provider"] as? String == fixture.id.rawValue)
            #expect(payload["usagePercent"] as? Double == 0.42)
            #expect(payload["secondaryUsagePercent"] as? Double == 0.52)
            #expect(payload["account"] as? String == (hidePersonalInfo ? nil : "fixture@example.test"))
        }
    }

    @Test
    func `plugin quota hooks share native crossing and reset semantics`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.settings.sessionQuotaNotificationsEnabled = false
        fixture.settings.quotaWarningNotificationsEnabled = false
        fixture.settings.limitResetNotificationsEnabled = false
        let low = Self.capture(.quotaLow, fixture: fixture, provider: fixture.id.rawValue, threshold: 0.7)
        let reached = Self.capture(.quotaReached, fixture: fixture, provider: fixture.id.rawValue)
        let reset = Self.capture(.quotaReset, fixture: fixture, provider: fixture.id.rawValue)
        func publish(_ session: Double, _ weekly: Double, _ time: Double) {
            fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: Self.snapshot(session, weekly, time))
        }
        publish(80, 60, 1)
        publish(50, 80, 2)
        let payload = try await Self.payload(at: low)
        #expect(payload["window"] as? String == QuotaWarningWindow.weekly.displayName)
        #expect(payload["usagePercent"] as? Double == 0.8)
        #expect(!FileManager.default.fileExists(atPath: reset.path))
        publish(100, 80, 3)
        #expect(try await Self.payload(at: reached)["usagePercent"] as? Double == 1)
        publish(2, 80, 4)
        publish(0, 80, 5)
        let resetPayload = try await Self.payload(at: reset)
        #expect(resetPayload["window"] as? String == QuotaWarningWindow.session.displayName)
        #expect(resetPayload["usagePercent"] as? Double == 0)
        let key = UsageStore.limitResetDetectorStateKey(provider: fixture.id, accountIdentifier: fixture.id.rawValue)
        #expect(fixture.store.sessionLimitResetDetectorStates[key]?.wasAboveThreshold == false)
        #expect(fixture.store.weeklyLimitResetDetectorStates[key]?.wasAboveThreshold == true)
        let persisted: [String: UsageStore.LimitResetDetectorState] = UsageStore.loadPlanUtilizationStates(
            from: fixture.settings.userDefaults,
            defaultsKey: UsageStore.sessionLimitResetDetectorDefaultsKey,
            logName: "fixture")
        #expect(persisted[key]?.lastObservedAt == Date(timeIntervalSince1970: 5))
        publish(0, 80, 6)
        #expect(fixture.store.quotaLowHookUsage.values.sorted() == [0, 0.8])
        publish(0, 0, 7)
        let weeklyReset = try await Self.payload(at: reset, window: QuotaWarningWindow.weekly.displayName)
        #expect(weeklyReset["usagePercent"] as? Double == 0)
    }

    @Test
    func `plugin hook state follows fetch identity and discovery without sharing providers`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secondID = try #require(ProviderInstanceID(rawValue: "second-fixture"))
        let secondSource = try String(contentsOf: fixture.pluginURL, encoding: .utf8)
            .replacingOccurrences(of: "refresh-fixture", with: secondID.rawValue)
        try Data(secondSource.utf8).write(to: fixture.pluginURL.deletingLastPathComponent()
            .appendingPathComponent("second.js"))
        fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        let reached = Self.capture(.quotaReached, fixture: fixture)
        let firstUsage = Self.capture(.usageUpdated, fixture: fixture, provider: fixture.id.rawValue)
        let secondUsage = Self.capture(.usageUpdated, fixture: fixture, provider: secondID.rawValue)
        fixture.store.emitUserPluginHooks(provider: secondID, snapshot: Self.snapshot(20, 40, 1))
        #expect(try await Self.payload(at: secondUsage)["provider"] as? String == secondID.rawValue)
        #expect(!FileManager.default.fileExists(atPath: firstUsage.path))
        #expect(!FileManager.default.fileExists(atPath: reached.path))
        fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: Self.snapshot(100, 60, 1))
        #expect(try await Self.payload(at: reached)["provider"] as? String == fixture.id.rawValue)
        #expect(try await Self.payload(at: firstUsage)["provider"] as? String == fixture.id.rawValue)
        #expect(fixture.store.sessionQuotaTransitionStates[secondID]?.remaining == 80)
        let prior = fixture.store.sessionQuotaTransitionStates[fixture.id]
        fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.accentColor = "#FF0000" }
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == prior)
        fixture.settings.updatePluginConfig(instanceID: fixture.id) { $0.pluginSettings = ["ACCOUNT": "new"] }
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        for id in [fixture.id, secondID] {
            #expect(await fixture.store.hookRateLimiter.allow(HookEvent.usageUpdated(
                provider: id.rawValue, snapshot: Self.snapshot(20, 40, 2), account: nil)) == false)
        }
        #expect(fixture.store.sessionQuotaTransitionStates[secondID]?.remaining == 80)
        #expect(!fixture.store.sessionLimitResetDetectorStates.keys
            .contains { $0.hasPrefix(fixture.id.rawValue + ":") })
        let persisted: [String: UsageStore.LimitResetDetectorState] = UsageStore.loadPlanUtilizationStates(
            from: fixture.settings.userDefaults,
            defaultsKey: UsageStore.sessionLimitResetDetectorDefaultsKey,
            logName: "fixture")
        #expect(!persisted.keys.contains { $0.hasPrefix(fixture.id.rawValue + ":") })
        fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: Self.snapshot(20, 40, 2))
        fixture.settings.setPluginEnabled(fixture.id, enabled: false)
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        fixture.settings.setPluginEnabled(fixture.id, enabled: true)
        fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: Self.snapshot(20, 40, 3))
        fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: Self.snapshot(20, 40, 4))
        try FileManager.default.removeItem(at: fixture.pluginURL)
        fixture.store.refreshUserPluginDiscovery(loader: fixture.loader)
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        #expect(!HookRule(event: .usageUpdated, provider: fixture.id.rawValue, executable: "/bin/true")
            .hasKnownProvider)
    }

    @Test
    func `unknown cadence and weekly primary do not become session reset hooks`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 1)))
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id] == nil)
        #expect(fixture.store.sessionLimitResetDetectorStates.isEmpty)
        #expect(fixture.store.weeklyLimitResetDetectorStates.count == 1)
        fixture.store.clearUserPluginHookState(fixture.id)
        fixture.store.emitUserPluginHooks(provider: fixture.id, snapshot: UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(timeIntervalSince1970: 2)))
        #expect(fixture.store.sessionQuotaTransitionStates[fixture.id]?.remaining == 0)
        #expect(fixture.store.sessionLimitResetDetectorStates.isEmpty)
    }

    @Test
    func `startup removes dormant plugin reset states from shared persistence`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let state = UsageStore.LimitResetDetectorState(
            wasAboveThreshold: true, lastObservedAt: .distantPast, sourceRawValue: nil)
        let retained = fixture.id.rawValue + ":fixture-owner"
        let retired = "removed-fixture:fixture-owner"
        let builtin = "claude:fixture-owner"
        let data = try JSONEncoder().encode([retained: state, retired: state, builtin: state])
        for key in [UsageStore.sessionLimitResetDetectorDefaultsKey, UsageStore.weeklyLimitResetDetectorDefaultsKey] {
            fixture.settings.userDefaults.set(data, forKey: key)
        }
        let restored = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: fixture.settings,
            startupBehavior: .testing,
            environmentBase: [:],
            pluginApprovalStore: fixture.store.pluginApprovalStore)
        #expect(Set(restored.sessionLimitResetDetectorStates.keys) == [retained, builtin])
        #expect(Set(restored.weeklyLimitResetDetectorStates.keys) == [retained, builtin])
        for key in [UsageStore.sessionLimitResetDetectorDefaultsKey, UsageStore.weeklyLimitResetDetectorDefaultsKey] {
            let persisted: [String: UsageStore.LimitResetDetectorState] = UsageStore.loadPlanUtilizationStates(
                from: fixture.settings.userDefaults, defaultsKey: key, logName: "fixture")
            #expect(Set(persisted.keys) == [retained, builtin])
        }
    }

    private static func snapshot(_ session: Double, _ weekly: Double, _ time: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: session, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: weekly, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: time))
    }

    private static func capture(
        _ event: HookEventType,
        fixture: Fixture,
        provider: String? = nil,
        threshold: Double? = nil) -> URL
    {
        let output = fixture.root.appendingPathComponent(UUID().uuidString + ".json")
        fixture.settings.addHookRule(HookRule(
            event: event,
            provider: provider,
            threshold: threshold,
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"/bin/cat > "$1""#,
                "hook",
                output.path,
            ]))
        fixture.settings.setHooksEnabled(true)
        return output
    }

    private static func payload(at url: URL, window: String? = nil) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               window == nil || value["window"] as? String == window
            { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CaptureError.missingPayload
    }

    private enum CaptureError: Error { case missingPayload }
}
#endif
