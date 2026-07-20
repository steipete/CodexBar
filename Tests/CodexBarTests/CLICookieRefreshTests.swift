import Commander
import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
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
    func `all provider selection is descriptor driven`() throws {
        let targets = try CodexBarCLI.cookieRefreshTargets(rawProvider: nil, refreshAll: true)

        #expect(targets.count > 2)
        #expect(targets.contains(where: { $0.id == .claude }))
        #expect(targets.contains(where: { $0.id == .opencode }))
        #expect(targets.allSatisfy { $0.metadata.browserCookieOrder != nil })
        #expect(targets.allSatisfy { $0.fetchPlan.sourceModes.contains(.web) })
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

    @Test
    func `keychain failure reuses actionable denial hint`() {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        BrowserCookieAccessGate.recordDenied(for: .chrome)

        KeychainAccessGate.withTaskOverrideForTesting(false) {
            let result = CodexBarCLI.cookieRefreshFailure(
                provider: .opencode,
                error: NSError(domain: "opaque-test-marker", code: 1))

            #expect(result.message ==
                "Chrome cookie decryption was declined in Keychain; retry with --allow-keychain-prompt.")
            #expect(!result.message.contains("opaque-test-marker"))
        }
    }
    #endif
}
