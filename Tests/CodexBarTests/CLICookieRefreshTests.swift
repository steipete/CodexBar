import Commander
import Foundation
import Testing
#if os(macOS)
import SweetCookieKit
#endif
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized, ProviderTransportRegressionFixtures())
struct CLICookieRefreshTests {
    @Test
    func `cookie refresh parses explicit keychain acknowledgement`() throws {
        let parser = CommandParser(signature: CommandSignature.describe(CookieOptions()))
        let parsed = try parser.parse(arguments: [
            "--provider", "opencodego", "--allow-keychain-prompt", "--json",
        ])

        #expect(parsed.options["provider"] == ["opencodego"])
        #expect(parsed.flags.contains("allowKeychainPrompt"))
        #expect(parsed.flags.contains("jsonShortcut"))
    }

    #if os(macOS)
    @Test
    func `Muse AI participates in explicit and all provider cookie refresh`() throws {
        let targets = try CodexBarCLI.cookieRefreshTargets(rawProvider: nil, refreshAll: true)
        #expect(targets.contains { $0.id == .museai })
        let explicit = try CodexBarCLI.cookieRefreshTargets(rawProvider: "museai", refreshAll: false)
        #expect(explicit.map(\.id) == [.museai])
        #expect(CodexBarCLI.cookieRefreshBrowserOrder(descriptor: explicit[0], config: nil)
            == ProviderBrowserCookieDefaults.defaultImportOrder)
    }

    @Test
    func `all provider selection is descriptor driven`() throws {
        let targets = try CodexBarCLI.cookieRefreshTargets(rawProvider: nil, refreshAll: true)

        #expect(targets.count > 2)
        #expect(targets.contains(where: { $0.id == .claude }))
        #expect(targets.contains(where: { $0.id == .opencode }))
        #expect(targets.allSatisfy { $0.metadata.browserCookieOrder != nil })
        #expect(targets.allSatisfy { $0.fetchPlan.sourceModes.contains(.web) })
    }

    @Test
    func `catalog order providers remain cookie refresh targets`() throws {
        let all = try CodexBarCLI.cookieRefreshTargets(rawProvider: nil, refreshAll: true)
        let typesafe = try CodexBarCLI.cookieRefreshTargets(rawProvider: "typesafe", refreshAll: false)

        #expect(all.contains(where: { $0.id == .typesafe }))
        #expect(typesafe.map(\.id) == [.typesafe])
        #expect(typesafe.first?.metadata.browserCookieOrder == ProviderBrowserCookieDefaults.defaultImportOrder)
    }

    @Test
    func `prompt capable refresh is gated before provider work`() async {
        var operationCalled = false
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)

        let results = await CodexBarCLI.performCookieRefreshes(
            targets: [descriptor],
            allowKeychainPrompt: false)
        { _ in
            operationCalled = true
            return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
        }

        #expect(operationCalled == false)
        #expect(results.count == 1)
        #expect(results[0].status == .blocked)
        #expect(results[0].message.contains("--allow-keychain-prompt"))
    }

    @Test
    func `preflight skip does not require keychain acknowledgement`() async {
        var operationCalled = false
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)

        let results = await CodexBarCLI.performCookieRefreshes(
            targets: [descriptor],
            allowKeychainPrompt: false,
            preflight: { descriptor in
                CookieRefreshResult(provider: descriptor.cli.name, status: .skipped, message: "manual")
            },
            operation: { _ in
                operationCalled = true
                return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
            })

        #expect(operationCalled == false)
        #expect(results.count == 1)
        #expect(results[0].status == .skipped)
    }

    @Test(arguments: [nil, "edge", "chrome", "safari"] as [String?], [false, true])
    func `profile refresh acknowledgement applies only to the configured browser`(
        browserID: String?, acknowledged: Bool) async
    {
        var provider = ProviderConfig(id: .langdock)
        provider.browserID = browserID
        provider.browserProfileID = "/synthetic/Profile"
        let config = CodexBarConfig(providers: [provider])
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .langdock)
        #expect(CodexBarCLI.cookieRefreshBrowserOrder(descriptor: descriptor, config: config).map(\.rawValue)
            == [browserID ?? "edge"])
        var operationCalled = false
        let results = await CodexBarCLI.performCookieRefreshes(
            targets: [descriptor], allowKeychainPrompt: acknowledged, config: config)
        { descriptor in
            operationCalled = true
            #expect(ProviderInteractionContext.current == .userInitiated)
            return CookieRefreshResult(provider: descriptor.cli.name, status: .refreshed, message: "synthetic success")
        }
        let permitted = acknowledged || browserID == "safari"
        #expect(operationCalled == permitted)
        #expect(results.first?.status == (permitted ? .refreshed : .blocked))
    }

    @Test(arguments: ["firefox", "", "Chrome"])
    func `invalid selected browser cannot fall back to a different browser`(browserID: String) {
        var provider = ProviderConfig(id: .langdock)
        provider.browserID = browserID
        provider.browserProfileID = "/synthetic/Profile"
        #expect(CodexBarCLI.cookieRefreshBrowserOrder(
            descriptor: ProviderDescriptorRegistry.descriptor(for: .langdock),
            config: CodexBarConfig(providers: [provider])).isEmpty)
    }

    @Test
    func `failed refresh preserves default cookie and unrelated account scopes`() async {
        let provider = UsageProvider.opencode
        let accountScope = CookieHeaderCache.Scope.managedAccount(UUID())
        let service = "com.steipete.codexbar.tests.cookie-refresh.\(UUID().uuidString)"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: provider,
                    cookieHeader: "default-test-cookie",
                    sourceLabel: "Test default")
                CookieHeaderCache.store(
                    provider: provider,
                    scope: accountScope,
                    cookieHeader: "account-test-cookie",
                    sourceLabel: "Test account")

                let result = await CodexBarCLI.withCookieRefreshCacheSuppressed(
                    provider: provider,
                    providerName: "opencode")
                {
                    #expect(CookieHeaderCache.load(provider: provider) == nil)
                    #expect(CookieHeaderCache.loadSerialized(provider: provider) == nil)
                    #expect(CookieHeaderCache.load(provider: provider, scope: accountScope) == nil)
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "unvalidated-test-cookie",
                        sourceLabel: "Test unvalidated")
                    #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "unvalidated-test-cookie")
                    return CookieRefreshResult(provider: "opencode", status: .failed, message: "test failure")
                }

                #expect(result.status == .failed)
                #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "default-test-cookie")
                #expect(CookieHeaderCache.load(provider: provider, scope: accountScope)?.sourceLabel == "Test account")
            }
        }
    }

    @Test
    func `successful refresh keeps replacement cookie`() async {
        let provider = UsageProvider.opencode
        let service = "com.steipete.codexbar.tests.cookie-refresh.\(UUID().uuidString)"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                let stored = CookieHeaderCache.storeResult(
                    provider: provider,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old",
                    authenticationFailurePolicy: .stopFallback)
                #expect(stored)

                let result = await CodexBarCLI.withCookieRefreshCacheSuppressed(
                    provider: provider,
                    providerName: "opencode")
                {
                    let observation = CookieHeaderCache.observeForConditionalMutation(provider: provider)
                    #expect(observation.entry == nil)
                    let stored = CookieHeaderCache.storeIfObservationCurrent(
                        provider: provider,
                        expected: observation,
                        cookieHeader: "new-test-cookie",
                        sourceLabel: "Test new")
                    #expect(stored)
                    return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "ok")
                }

                #expect(result.status == .refreshed)
                #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "new-test-cookie")
            }
        }
    }

    @Test
    func `successful provider result without a staged cookie fails safely`() async {
        let provider = UsageProvider.opencode
        let service = "com.steipete.codexbar.tests.cookie-refresh.\(UUID().uuidString)"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: provider,
                    cookieHeader: "old-test-cookie",
                    sourceLabel: "Test old")

                let result = await CodexBarCLI.withCookieRefreshCacheSuppressed(
                    provider: provider,
                    providerName: "opencode")
                {
                    CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
                }

                #expect(result.status == .failed)
                #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "old-test-cookie")
            }
        }
    }

    @Test
    func `validated nonpersistent refresh succeeds without changing persisted cookies`() async {
        let service = "com.steipete.codexbar.tests.cookie-refresh.\(UUID().uuidString)"
        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(provider: .langdock, cookieHeader: "old-test-cookie", sourceLabel: "Test old")
                let result = await CodexBarCLI.withCookieRefreshCacheSuppressed(
                    provider: .langdock, providerName: "langdock")
                {
                    #expect(CookieHeaderCache.load(provider: .langdock) == nil)
                    CookieHeaderCache.markNonpersistentRefreshValidated(provider: .langdock)
                    return CookieRefreshResult(provider: "langdock", status: .refreshed, message: "validated")
                }
                #expect(result.status == .refreshed)
                #expect(CookieHeaderCache.load(provider: .langdock)?.cookieHeader == "old-test-cookie")
            }
        }
    }

    @Test
    func `multiple staged replacements fail before changing persisted cookies`() async {
        let provider = UsageProvider.opencode
        let accountScope = CookieHeaderCache.Scope.managedAccount(UUID())
        let service = "com.steipete.codexbar.tests.cookie-refresh.\(UUID().uuidString)"

        await KeychainCacheStore.withServiceOverrideForTesting(service) {
            await KeychainCacheStore.withImplicitTestStoreForTesting {
                CookieHeaderCache.store(
                    provider: provider,
                    cookieHeader: "old-default-cookie",
                    sourceLabel: "Test old default")
                CookieHeaderCache.store(
                    provider: provider,
                    scope: accountScope,
                    cookieHeader: "old-account-cookie",
                    sourceLabel: "Test old account")

                let result = await CodexBarCLI.withCookieRefreshCacheSuppressed(
                    provider: provider,
                    providerName: "opencode")
                {
                    CookieHeaderCache.store(
                        provider: provider,
                        cookieHeader: "new-default-cookie",
                        sourceLabel: "Test new default")
                    CookieHeaderCache.store(
                        provider: provider,
                        scope: accountScope,
                        cookieHeader: "new-account-cookie",
                        sourceLabel: "Test new account")
                    return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
                }

                #expect(result.status == .failed)
                #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "old-default-cookie")
                #expect(CookieHeaderCache.load(provider: provider, scope: accountScope)?.cookieHeader ==
                    "old-account-cookie")
            }
        }
    }

    @Test
    func `commit detaches the gate before later writes`() {
        let provider = UsageProvider.opencode
        let service = "com.steipete.codexbar.tests.cookie-refresh.\(UUID().uuidString)"

        KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.withImplicitTestStoreForTesting {
                guard let gate = CookieHeaderCache.beginRefreshReadSuppression(provider: provider) else {
                    Issue.record("Expected refresh gate")
                    return
                }
                CookieHeaderCache.store(
                    provider: provider,
                    cookieHeader: "committed-cookie",
                    sourceLabel: "Test committed")
                #expect(CookieHeaderCache.commitRefreshReadSuppression(gate).committedCount == 1)

                CookieHeaderCache.store(
                    provider: provider,
                    cookieHeader: "later-cookie",
                    sourceLabel: "Test later")
                CookieHeaderCache.endRefreshReadSuppression(gate)
                #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "later-cookie")
            }
        }
    }

    @Test
    func `explicit acknowledgement is user initiated and is the only cooldown bypass`() async {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        let start = Date(timeIntervalSince1970: 2000)
        BrowserCookieAccessGate.recordDenied(for: .chrome, now: start)
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .opencode)
        var unacknowledgedOperationCalled = false

        var observedInteraction: ProviderInteraction?
        var explicitRetryAllowed = false
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                _ = await CodexBarCLI.performCookieRefreshes(
                    targets: [descriptor],
                    allowKeychainPrompt: false)
                { _ in
                    unacknowledgedOperationCalled = true
                    return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "unexpected")
                }

                _ = await CodexBarCLI.performCookieRefreshes(
                    targets: [descriptor],
                    allowKeychainPrompt: true)
                { _ in
                    observedInteraction = ProviderInteractionContext.current
                    explicitRetryAllowed = BrowserCookieAccessGate.shouldAttempt(
                        .chrome,
                        now: start.addingTimeInterval(1))
                    return CookieRefreshResult(provider: "opencode", status: .refreshed, message: "ok")
                }
            }
        }

        #expect(unacknowledgedOperationCalled == false)
        #expect(observedInteraction == .userInitiated)
        #expect(explicitRetryAllowed)
    }

    @Test
    func `acknowledged cookie refresh shares one interactive read across providers`() async {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        var interactiveReads = 0
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in .allowed } operation: {
                let results = await CodexBarCLI.performCookieRefreshes(
                    targets: [UsageProvider.opencode, .mimo].map { ProviderDescriptorRegistry.descriptor(for: $0) },
                    allowKeychainPrompt: true)
                { descriptor in
                    _ = try? BrowserCookieAccessGate.withRecordReadInteractionPolicy {
                        if BrowserCookieKeychainAccessGate.isUserInteractionDisallowed {
                            throw BrowserCookieError.accessDenied(browser: .chrome, details: "Synthetic")
                        }
                        interactiveReads += 1
                    }
                    return CookieRefreshResult(provider: descriptor.cli.name, status: .refreshed, message: "Synthetic")
                }
                #expect(results.count == 2)
            }
        }
        #expect(interactiveReads == 1)
    }

    @Test
    func `classified cookie failures retain safe category hints`() throws {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        try KeychainAccessGate.withTaskOverrideForTesting(false) {
            let hints: [ProviderFetchClassifiedError.Kind: String] = [
                .authenticationExpired: "The provider rejected the browser session. Sign in again and retry.",
                .permissionDenied:
                    "Permission was denied while refreshing the browser session. Check access and retry.",
                .rateLimited: "The provider rate limited the refresh. Wait and retry.",
                .providerUnavailable: "The provider is temporarily unavailable. Retry later.",
                .parseFailure: "The provider response could not be read. Check for a CodexBar update.",
                .networkFailure: "The provider could not be reached. Check your connection and retry.",
                .apiFailure: "The provider could not validate the browser session. Retry later.",
            ]
            for kind in ProviderFetchClassifiedError.Kind.allCases {
                let result = CodexBarCLI.cookieRefreshFailure(
                    provider: .raycast,
                    error: ProviderFetchClassifiedError(kind: kind, message: "opaque-test-marker"))
                #expect(result.status == .failed)
                if let hint = hints[kind] {
                    #expect(result.message == hint)
                } else {
                    #expect(result.message.contains("No browser session cookie was refreshed"))
                }
                #expect(!CodexBarCLI.cookieRefreshText([result]).contains("opaque-test-marker"))
                let data = try JSONEncoder().encode(result)
                let json = try #require(String(data: data, encoding: .utf8))
                #expect(!json.contains("opaque-test-marker"))
            }
        }
    }

    @Test(arguments: ["edge", "chrome", "safari"], [false, true])
    func `wrapped profile failures use only the selected browser access hints`(browserID: String, disabled: Bool) {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        BrowserCookieAccessGate.recordDenied(for: .edge)
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        var provider = ProviderConfig(id: .langdock)
        provider.browserID = browserID
        provider.browserProfileID = "/synthetic/Profile"
        KeychainAccessGate.withTaskOverrideForTesting(disabled) {
            for kind in [ProviderFetchClassifiedError.Kind.permissionDenied, .missingCredential] {
                let result = CodexBarCLI.cookieRefreshFailure(
                    provider: .langdock,
                    error: ProviderBrowserSessionFailure(owner: nil, underlyingError: ProviderFetchClassifiedError(
                        kind: kind, message: "opaque-test-marker")),
                    config: CodexBarConfig(providers: [provider]))
                if browserID == "safari" {
                    let expected = kind == .permissionDenied
                        ? "Permission was denied while refreshing the browser session. Check access and retry."
                        : "No browser session cookie was refreshed. Sign in in a configured browser and retry."
                    #expect(result.message == expected)
                } else {
                    let browserName = browserID == "edge" ? "Edge" : "Chrome"
                    #expect(result.message.contains("\(browserName) cookie decryption"))
                    #expect(result.message.contains(disabled ? "disabled" : "declined"))
                }
                #expect(!result.message.contains("opaque-test-marker"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `plugin HTTP rejection reaches cookie refresh output`(engine: ProviderPluginEngineKind) async throws {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        let runtime = try ProviderPluginRuntime(source: """
        defineProvider({id: 'raycast', name: 'Fixture', endpoints: ['https://cookies.example.test'],
          settings: [], capabilities: ['http-status'],
          async fetchUsage(ctx) {
            const response = await ctx.http.getJSON('https://cookies.example.test/session');
            if (response.status === 401) throw ctx.fail.authenticationExpired('opaque-test-marker');
            throw new Error('Expected HTTP 401');
          }
        });
        """, transport: ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            return try (Data("{}".utf8), #require(HTTPURLResponse(
                url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
        }, engine: engine)
        do {
            _ = try await runtime.fetchUsage()
            Issue.record("Expected authentication failure")
        } catch {
            #expect((error as? ProviderFetchClassifiedError)?.kind == .authenticationExpired)
            KeychainAccessGate.withTaskOverrideForTesting(false) {
                let result = CodexBarCLI.cookieRefreshFailure(provider: .raycast, error: error)
                #expect(result.message == "The provider rejected the browser session. Sign in again and retry.")
                #expect(!result.message.contains("opaque-test-marker"))
            }
        }
    }

    @Test
    func `header importer retains explicit retry after leaving its task`() async throws {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        BrowserCookieAccessGate.recordDenied(for: .chrome)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let service = "com.steipete.codexbar.tests.header-import.\(UUID().uuidString)"
        let domain = "cookies.example.test"
        let broker = ProviderInteractionContext.$current.withValue(.userInitiated) {
            BrowserCookieAccessGate.withExplicitRetry(bypassingCooldown: true) {
                ProviderPluginCookieBroker(
                    provider: .raycast,
                    domains: [domain],
                    settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                    batches: { _, batch in
                        #expect(ProviderInteractionContext.current == .userInitiated)
                        return KeychainAccessGate.withTaskOverrideForTesting(false) {
                            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                                .interactionRequired
                            } operation: {
                                #expect(BrowserCookieAccessGate.shouldAttempt(.chrome))
                                return batch == 0 ? [("session=synthetic", "Chrome")] : nil
                            }
                        }
                    })
            }
        }
        let session = try await Task.detached {
            try KeychainCacheStore.withServiceOverrideForTesting(service) {
                try KeychainCacheStore.withImplicitTestStoreForTesting {
                    try CookieHeaderCache.withLegacyBaseURLOverrideForTesting(storage) {
                        try broker.nextSession(domain: domain)
                    }
                }
            }
        }.value
        #expect(session?.header == "session=synthetic")
    }

    @Test
    func `raw provider failures cannot leak cookie values`() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            let privateMarker = "opaque-test-marker"
            let error = NSError(
                domain: privateMarker,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: privateMarker])

            let result = CodexBarCLI.cookieRefreshFailure(provider: .opencode, error: error)
            let text = CodexBarCLI.cookieRefreshText([result])
            let encoded = try? JSONEncoder().encode(result)
            let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            #expect(!text.contains(privateMarker))
            #expect(!json.contains(privateMarker))
            #expect(text.contains("six-hour denial cooldown"))
        }
    }

    @Test(arguments: [false, true], ProviderFetchClassifiedError.Kind.allCases)
    func `keychain failure takes precedence over classified hints`(
        disabled: Bool, kind: ProviderFetchClassifiedError.Kind)
    {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        BrowserCookieAccessGate.recordDenied(for: .chrome)

        KeychainAccessGate.withTaskOverrideForTesting(disabled) {
            let result = CodexBarCLI.cookieRefreshFailure(
                provider: .opencode,
                error: ProviderFetchClassifiedError(kind: kind, message: "opaque-test-marker"))

            let expected = disabled ?
                "Chrome cookie decryption is disabled in CodexBar; enable Keychain access and refresh." :
                "Chrome cookie decryption was declined in Keychain; " +
                "rerun with --allow-keychain-prompt to request Keychain access again."
            #expect(result.message == expected)
            #expect(!result.message.contains("opaque-test-marker"))
        }
    }
    #endif
}
