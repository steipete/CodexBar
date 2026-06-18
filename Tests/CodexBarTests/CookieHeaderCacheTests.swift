import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CookieHeaderCacheTests {
    private struct WrongEntry: Codable {
        let value: String
    }

    @Test
    func `stores and loads entry`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let provider: UsageProvider = .codex
        let storedAt = Date(timeIntervalSince1970: 0)
        CookieHeaderCache.store(
            provider: provider,
            cookieHeader: "auth=abc",
            sourceLabel: "Chrome",
            now: storedAt)

        let loaded = CookieHeaderCache.load(provider: provider)
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(loaded?.cookieHeader == "auth=abc")
        #expect(loaded?.sourceLabel == "Chrome")
        #expect(loaded?.storedAt == storedAt)
    }

    @Test
    func `stores separate codex entries per managed account scope`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let provider: UsageProvider = .codex
        let accountA = UUID()
        let accountB = UUID()

        CookieHeaderCache.store(
            provider: provider,
            scope: .managedAccount(accountA),
            cookieHeader: "auth=account-a",
            sourceLabel: "Chrome")
        CookieHeaderCache.store(
            provider: provider,
            scope: .managedAccount(accountB),
            cookieHeader: "auth=account-b",
            sourceLabel: "Safari")
        defer {
            CookieHeaderCache.clear(provider: provider, scope: .managedAccount(accountA))
            CookieHeaderCache.clear(provider: provider, scope: .managedAccount(accountB))
        }

        #expect(CookieHeaderCache.load(provider: provider, scope: .managedAccount(accountA))?
            .cookieHeader == "auth=account-a")
        #expect(CookieHeaderCache.load(provider: provider, scope: .managedAccount(accountB))?
            .cookieHeader == "auth=account-b")
        #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == nil)
    }

    @Test
    func `provider global scope remains available without managed account`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let provider: UsageProvider = .codex

        CookieHeaderCache.store(
            provider: provider,
            cookieHeader: "auth=system",
            sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "auth=system")
        #expect(CookieHeaderCache.load(provider: provider, scope: .managedAccount(UUID())) == nil)
    }

    @Test
    func `claude cookie scopes isolate browser cache from managed accounts`() {
        self.withIsolatedCookieCache {
            let accountA = UUID()
            let accountB = UUID()

            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-browser",
                sourceLabel: "Safari")
            CookieHeaderCache.store(
                provider: .claude,
                scope: .managedAccount(accountA),
                cookieHeader: "sessionKey=sk-ant-account-a",
                sourceLabel: "Chrome")
            CookieHeaderCache.store(
                provider: .claude,
                scope: .managedAccount(accountB),
                cookieHeader: "sessionKey=sk-ant-account-b",
                sourceLabel: "Edge")

            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-browser")
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountA))?
                .cookieHeader == "sessionKey=sk-ant-account-a")
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountB))?
                .cookieHeader == "sessionKey=sk-ant-account-b")

            CookieHeaderCache.clear(provider: .claude)
            #expect(CookieHeaderCache.load(provider: .claude) == nil)
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountA))?
                .cookieHeader == "sessionKey=sk-ant-account-a")
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountB))?
                .cookieHeader == "sessionKey=sk-ant-account-b")

            CookieHeaderCache.clear(provider: .claude, scope: .managedAccount(accountA))
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountA)) == nil)
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountB))?
                .cookieHeader == "sessionKey=sk-ant-account-b")
        }
    }

    @Test
    func `claude unreadable managed store sentinel is isolated from account cookies`() {
        self.withIsolatedCookieCache {
            let accountID = UUID()

            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-global",
                sourceLabel: "Safari")
            CookieHeaderCache.store(
                provider: .claude,
                scope: .managedAccount(accountID),
                cookieHeader: "sessionKey=sk-ant-account",
                sourceLabel: "Chrome")
            CookieHeaderCache.store(
                provider: .claude,
                scope: .managedStoreUnreadable,
                cookieHeader: "sessionKey=sk-ant-unreadable-store",
                sourceLabel: "Unreadable managed account store")

            CookieHeaderCache.clear(provider: .claude, scope: .managedAccount(accountID))
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(accountID)) == nil)
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-global")
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedStoreUnreadable)?
                .cookieHeader == "sessionKey=sk-ant-unreadable-store")

            CookieHeaderCache.clear(provider: .claude)
            #expect(CookieHeaderCache.load(provider: .claude) == nil)
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedStoreUnreadable)?
                .cookieHeader == "sessionKey=sk-ant-unreadable-store")

            let cleared = CookieHeaderCache.clearAllScopesDetailed(provider: .claude)
            #expect(cleared == CookieHeaderCache.ClearSummary(clearedCount: 1, failedCount: 0))
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedStoreUnreadable) == nil)
        }
    }

    @Test
    func `claude clear all scopes does not remove other provider cookie caches`() {
        self.withIsolatedCookieCache {
            let claudeAccount = UUID()
            let codexAccount = UUID()

            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-claude-global",
                sourceLabel: "Safari")
            CookieHeaderCache.store(
                provider: .claude,
                scope: .managedAccount(claudeAccount),
                cookieHeader: "sessionKey=sk-ant-claude-account",
                sourceLabel: "Chrome")
            CookieHeaderCache.store(provider: .codex, cookieHeader: "auth=codex-global", sourceLabel: "Chrome")
            CookieHeaderCache.store(
                provider: .codex,
                scope: .managedAccount(codexAccount),
                cookieHeader: "auth=codex-account",
                sourceLabel: "Safari")
            CookieHeaderCache.store(provider: .perplexity, cookieHeader: "pplx=web", sourceLabel: "Chrome")

            let cleared = CookieHeaderCache.clearAllScopesDetailed(provider: .claude)

            #expect(cleared == CookieHeaderCache.ClearSummary(clearedCount: 2, failedCount: 0))
            #expect(CookieHeaderCache.load(provider: .claude) == nil)
            #expect(CookieHeaderCache.load(provider: .claude, scope: .managedAccount(claudeAccount)) == nil)
            #expect(CookieHeaderCache.load(provider: .codex)?.cookieHeader == "auth=codex-global")
            #expect(CookieHeaderCache.load(provider: .codex, scope: .managedAccount(codexAccount))?
                .cookieHeader == "auth=codex-account")
            #expect(CookieHeaderCache.load(provider: .perplexity)?.cookieHeader == "pplx=web")
        }
    }

    @Test
    func `migrates legacy file to keychain`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        let storedAt = Date(timeIntervalSince1970: 0)
        let entry = CookieHeaderCache.Entry(
            cookieHeader: "auth=legacy",
            storedAt: storedAt,
            sourceLabel: "Legacy")
        let legacyURL = legacyBase.appendingPathComponent("\(provider.rawValue)-cookie.json")

        CookieHeaderCache.store(entry, to: legacyURL)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == true)

        let loaded = CookieHeaderCache.load(provider: provider)
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(loaded?.cookieHeader == "auth=legacy")
        #expect(loaded?.sourceLabel == "Legacy")
        #expect(loaded?.storedAt == storedAt)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)

        let loadedAgain = CookieHeaderCache.load(provider: provider)
        #expect(loadedAgain?.cookieHeader == "auth=legacy")
    }

    @Test
    func `serialized load migrates legacy file to keychain`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        let legacyURL = legacyBase.appendingPathComponent("\(provider.rawValue)-cookie.json")
        CookieHeaderCache.store(
            CookieHeaderCache.Entry(
                cookieHeader: "auth=legacy",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Legacy"),
            to: legacyURL)

        let loaded = CookieHeaderCache.loadSerialized(provider: provider)
        defer { CookieHeaderCache.clear(provider: provider) }

        #expect(loaded?.cookieHeader == "auth=legacy")
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
        #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "auth=legacy")
    }

    #if os(macOS)
    @Test
    func `temporary keychain unavailability returns nil without migrating legacy file`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        let legacyURL = legacyBase.appendingPathComponent("\(provider.rawValue)-cookie.json")
        CookieHeaderCache.store(
            CookieHeaderCache.Entry(
                cookieHeader: "auth=legacy",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Legacy"),
            to: legacyURL)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == true)

        let loaded = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            CookieHeaderCache.load(provider: provider)
        }

        #expect(loaded == nil)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path) == true)

        switch KeychainCacheStore.load(key: .cookie(provider: provider), as: CookieHeaderCache.Entry.self) {
        case .missing:
            #expect(true)
        case .found, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected temporary miss not to migrate legacy cache")
        }
    }
    #endif

    @Test
    func `invalid keychain cache is cleared`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        let key = KeychainCacheStore.Key.cookie(provider: provider)
        KeychainCacheStore.store(key: key, entry: WrongEntry(value: "not-a-cookie-entry"))

        #expect(CookieHeaderCache.load(provider: provider) == nil)

        switch KeychainCacheStore.load(key: key, as: CookieHeaderCache.Entry.self) {
        case .missing:
            #expect(true)
        case .found, .temporarilyUnavailable, .invalid:
            #expect(Bool(false), "Expected invalid cookie cache to be cleared")
        }
    }

    @Test
    func `clear all scopes removes global scoped invalid and legacy cookie entries`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        let accountID = UUID()
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=global", sourceLabel: "Chrome")
        CookieHeaderCache.store(
            provider: provider,
            scope: .managedAccount(accountID),
            cookieHeader: "auth=scoped",
            sourceLabel: "Chrome")
        KeychainCacheStore.store(
            key: .cookie(provider: provider, scopeIdentifier: "managed-store-unreadable"),
            entry: WrongEntry(value: "invalid"))
        CookieHeaderCache.store(
            CookieHeaderCache.Entry(
                cookieHeader: "auth=legacy",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Legacy"),
            to: CookieHeaderCache.legacyURLForTesting(provider: provider))

        let cleared = CookieHeaderCache.clearAllScopesDetailed(provider: provider)

        #expect(cleared == CookieHeaderCache.ClearSummary(clearedCount: 4, failedCount: 0))
        #expect(!CookieHeaderCache.hasKeychainEntryForTesting(provider: provider))
        #expect(!CookieHeaderCache.hasKeychainEntryForTesting(provider: provider, scope: .managedAccount(accountID)))
        #expect(!CookieHeaderCache.hasKeychainEntryForTesting(provider: provider, scope: .managedStoreUnreadable))
        #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: provider))
    }

    @Test
    func `loadForDisplay memoizes keychain lookups`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=abc", sourceLabel: "Chrome")

        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=abc")

        // Remove the backing entry without going through CookieHeaderCache: the strict load
        // sees the change, the display path keeps serving the memoized snapshot.
        KeychainCacheStore.clear(key: .cookie(provider: provider))
        #expect(CookieHeaderCache.load(provider: provider) == nil)
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=abc")
    }

    @Test
    func `loadForDisplay memoizes missing entries`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)

        KeychainCacheStore.store(
            key: .cookie(provider: provider),
            entry: CookieHeaderCache.Entry(
                cookieHeader: "auth=behind-the-back",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Chrome"))
        defer { KeychainCacheStore.clear(key: .cookie(provider: provider)) }
        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)
    }

    @Test
    func `loadForDisplay migrates legacy cache asynchronously`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(
            CookieHeaderCache.Entry(
                cookieHeader: "auth=legacy-display",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Legacy"),
            to: CookieHeaderCache.legacyURLForTesting(provider: provider))

        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=legacy-display")
        for _ in 0..<500 {
            if !CookieHeaderCache.hasLegacyEntryForTesting(provider: provider),
               CookieHeaderCache.hasKeychainEntryForTesting(provider: provider)
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: provider))
        #expect(CookieHeaderCache.hasKeychainEntryForTesting(provider: provider))
        CookieHeaderCache.clear(provider: provider)
    }

    @Test
    func `delayed legacy migration cannot restore a cleared cache`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(
            CookieHeaderCache.Entry(
                cookieHeader: "auth=legacy-display",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Legacy"),
            to: CookieHeaderCache.legacyURLForTesting(provider: provider))

        CookieHeaderCache.clear(provider: provider)
        #expect(CookieHeaderCache.migrateLegacyEntryIfNeededForTesting(provider: provider) == nil)
        #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: provider))
        #expect(!CookieHeaderCache.hasKeychainEntryForTesting(provider: provider))
    }

    @Test
    func `legacy URL override supports concurrent teardown reads`() {
        let legacyBases = [
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
        ]
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        DispatchQueue.concurrentPerform(iterations: 5000) { index in
            if index.isMultiple(of: 3) {
                CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBases[index % legacyBases.count])
            } else if index.isMultiple(of: 5) {
                CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil)
            } else {
                _ = CookieHeaderCache.legacyURLForTesting(provider: .codex)
            }
        }

        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBases[0])
        #expect(
            CookieHeaderCache.legacyURLForTesting(provider: .codex)
                == legacyBases[0].appendingPathComponent("codex-cookie.json"))
    }

    #if os(macOS)
    @Test
    func `loadForDisplay throttles temporary keychain unavailability then retries`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }
        CookieHeaderCache.setDisplayUnavailableRetryIntervalOverrideForTesting(0.05)
        defer { CookieHeaderCache.setDisplayUnavailableRetryIntervalOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        KeychainCacheStore.store(
            key: .cookie(provider: provider),
            entry: CookieHeaderCache.Entry(
                cookieHeader: "auth=available-after-retry",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Chrome"))

        let unavailable = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            CookieHeaderCache.loadForDisplay(provider: provider)
        }

        #expect(unavailable == nil)
        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)

        try await Task.sleep(for: .milliseconds(60))
        var retried: CookieHeaderCache.Entry?
        for _ in 0..<500 {
            retried = CookieHeaderCache.loadForDisplay(provider: provider)
            if retried != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(retried?.cookieHeader == "auth=available-after-retry")
    }

    @Test
    func `temporary first display read returns a concurrent store`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        _ = CookieHeaderCache.beginDisplayReadGenerationForTesting(provider: provider)
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=concurrent", sourceLabel: "Chrome")

        #expect(CookieHeaderCache.currentDisplayEntryForTesting(provider: provider)?
            .cookieHeader == "auth=concurrent")
    }

    @Test
    func `failed keychain mutations preserve the display snapshot`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=old", sourceLabel: "Chrome")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=old")

        KeychainCacheStore.withStoreFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            CookieHeaderCache.store(provider: provider, cookieHeader: "auth=new", sourceLabel: "Safari")
        }
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=old")

        let cleared = KeychainCacheStore.withClearFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            CookieHeaderCache.clearDetailed(provider: provider)
        }
        #expect(cleared == CookieHeaderCache.ClearSummary(clearedCount: 0, failedCount: 1))
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=old")
        #expect(CookieHeaderCache.load(provider: provider)?.cookieHeader == "auth=old")
    }

    @Test
    func `legacy removal invalidates a snapshot after failed keychain clear`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        KeychainCacheStore.withServiceOverrideForTesting("legacy-clear-\(UUID().uuidString)") {
            let legacyBase = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
            defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

            let provider: UsageProvider = .codex
            CookieHeaderCache.store(
                CookieHeaderCache.Entry(
                    cookieHeader: "auth=legacy",
                    storedAt: Date(timeIntervalSince1970: 0),
                    sourceLabel: "Legacy"),
                to: CookieHeaderCache.legacyURLForTesting(provider: provider))

            let displayed = KeychainCacheStore.withStoreFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.loadForDisplay(provider: provider)
            }
            #expect(displayed?.cookieHeader == "auth=legacy")

            let cleared = KeychainCacheStore.withClearFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                CookieHeaderCache.clearDetailed(provider: provider)
            }

            #expect(cleared == CookieHeaderCache.ClearSummary(clearedCount: 1, failedCount: 1))
            #expect(!CookieHeaderCache.hasLegacyEntryForTesting(provider: provider))
            #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)
        }
    }

    @Test
    func `clear all reports keychain enumeration failure`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let summary = KeychainCacheStore.withKeysFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
            CookieHeaderCache.clearAllDetailed()
        }

        #expect(summary.failedCount >= 1)
    }

    @Test
    func `clear reports legacy file deletion failure`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
        defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(
            CookieHeaderCache.Entry(
                cookieHeader: "auth=legacy",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Legacy"),
            to: CookieHeaderCache.legacyURLForTesting(provider: provider))

        let summary = CookieHeaderCache.withLegacyRemovalFailureForTesting {
            CookieHeaderCache.clearDetailed(provider: provider)
        }

        #expect(summary.failedCount == 1)
        #expect(CookieHeaderCache.hasLegacyEntryForTesting(provider: provider))
    }
    #endif

    @Test
    func `store and clear update the display snapshot immediately`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=first", sourceLabel: "Chrome")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=first")

        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=second", sourceLabel: "Safari")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=second")

        CookieHeaderCache.clear(provider: provider)
        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)
    }

    @Test
    func `stale refresh cannot overwrite a newer store`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=old", sourceLabel: "Chrome")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=old")

        // A refresh scheduled now races with a store that lands before it commits.
        let staleGeneration = CookieHeaderCache.beginDisplayReadGenerationForTesting(provider: provider)
        let staleEntry = CookieHeaderCache.load(provider: provider)
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=new", sourceLabel: "Safari")

        let committed = CookieHeaderCache.commitDisplaySnapshotIfCurrentForTesting(
            provider: provider,
            entry: staleEntry,
            generation: staleGeneration)

        #expect(committed?.cookieHeader == "auth=new")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=new")
    }

    @Test
    func `stale refresh cannot resurrect a cleared snapshot`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=secret", sourceLabel: "Chrome")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=secret")

        let staleGeneration = CookieHeaderCache.beginDisplayReadGenerationForTesting(provider: provider)
        let staleEntry = CookieHeaderCache.load(provider: provider)
        CookieHeaderCache.clear(provider: provider)

        let committed = CookieHeaderCache.commitDisplaySnapshotIfCurrentForTesting(
            provider: provider,
            entry: staleEntry,
            generation: staleGeneration)

        #expect(committed == nil)
        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)
    }

    @Test
    func `stale refresh cannot survive clear all`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        CookieHeaderCache.store(provider: provider, cookieHeader: "auth=secret", sourceLabel: "Chrome")
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=secret")

        let staleGeneration = CookieHeaderCache.beginDisplayReadGenerationForTesting(provider: provider)
        let staleEntry = CookieHeaderCache.load(provider: provider)
        CookieHeaderCache.clearAll()

        CookieHeaderCache.commitDisplaySnapshotIfCurrentForTesting(
            provider: provider,
            entry: staleEntry,
            generation: staleGeneration)

        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)
    }

    @Test
    func `clear all invalidates an in flight first display population`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }

        let provider: UsageProvider = .codex
        KeychainCacheStore.store(
            key: .cookie(provider: provider),
            entry: CookieHeaderCache.Entry(
                cookieHeader: "auth=secret",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Chrome"))

        // A first display load registers its key, then reads the Keychain outside the lock.
        let staleGeneration = CookieHeaderCache.beginDisplayReadGenerationForTesting(provider: provider)
        let staleEntry = CookieHeaderCache.load(provider: provider)
        CookieHeaderCache.clearAll()

        let committed = CookieHeaderCache.commitDisplaySnapshotIfCurrentForTesting(
            provider: provider,
            entry: staleEntry,
            generation: staleGeneration)

        #expect(committed == nil)
        #expect(CookieHeaderCache.loadForDisplay(provider: provider) == nil)
    }

    @Test
    func `stale display snapshot revalidates off the calling path`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.resetDisplayCacheForTesting()
        defer { CookieHeaderCache.resetDisplayCacheForTesting() }
        CookieHeaderCache.setDisplayStalenessIntervalOverrideForTesting(0)
        defer { CookieHeaderCache.setDisplayStalenessIntervalOverrideForTesting(nil) }

        let provider: UsageProvider = .codex
        KeychainCacheStore.store(
            key: .cookie(provider: provider),
            entry: CookieHeaderCache.Entry(
                cookieHeader: "auth=old",
                storedAt: Date(timeIntervalSince1970: 0),
                sourceLabel: "Chrome"))
        #expect(CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=old")

        KeychainCacheStore.store(
            key: .cookie(provider: provider),
            entry: CookieHeaderCache.Entry(
                cookieHeader: "auth=new",
                storedAt: Date(timeIntervalSince1970: 1),
                sourceLabel: "Chrome"))

        // The stale lookup returns the old snapshot and schedules a revalidation.
        _ = CookieHeaderCache.loadForDisplay(provider: provider)
        var refreshed = false
        for _ in 0..<200 {
            if CookieHeaderCache.loadForDisplay(provider: provider)?.cookieHeader == "auth=new" {
                refreshed = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(refreshed)
    }

    @Test
    func `clear all removes every provider cookie key without decoding entries`() {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        KeychainCacheStore.withServiceOverrideForTesting("cookie-clear-all-\(UUID().uuidString)") {
            CookieHeaderCache.store(provider: .claude, cookieHeader: "auth=claude", sourceLabel: "Chrome")
            CookieHeaderCache.store(
                provider: .codex,
                scope: .managedAccount(UUID()),
                cookieHeader: "auth=codex",
                sourceLabel: "Chrome")
            KeychainCacheStore.store(
                key: .cookie(provider: .cursor),
                entry: WrongEntry(value: "invalid"))

            let cleared = CookieHeaderCache.clearAllDetailed()

            #expect(cleared.clearedCount >= 3)
            #expect(cleared.failedCount == 0)
            #expect(KeychainCacheStore.keys(category: "cookie").isEmpty)
        }
    }

    private func withIsolatedCookieCache<T>(_ operation: () -> T) -> T {
        KeychainCacheStore.withServiceOverrideForTesting("cookie-isolation-\(UUID().uuidString)") {
            let legacyBase = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            CookieHeaderCache.setLegacyBaseURLOverrideForTesting(legacyBase)
            defer { CookieHeaderCache.setLegacyBaseURLOverrideForTesting(nil) }
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            CookieHeaderCache.resetDisplayCacheForTesting()
            defer { CookieHeaderCache.resetDisplayCacheForTesting() }
            return operation()
        }
    }
}
