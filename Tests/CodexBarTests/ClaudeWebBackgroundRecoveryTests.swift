import Foundation
import Testing
@testable import CodexBarCore

/// Covers the same background-refresh recovery shape as `OllamaUsageFetcherRetryMappingTests`, applied to
/// `ClaudeWebAPIFetcher.fetchUsageSerialized`: a background refresh must still attempt browser-cookie recovery
/// after a stale cached cookie is invalidated (the gate itself decides whether that read needs an interactive
/// prompt), but must surface the original, more informative cached-auth error — not a generic "no session key
/// found" — when that recovery attempt comes back empty.
@Suite(.serialized)
struct ClaudeWebBackgroundRecoveryTests {
    private static let challengeMessage =
        "claude.ai is behind a Cloudflare challenge, often caused by VPN or datacenter networks. " +
        "Re-authenticating will not help. Switch Claude Usage source to OAuth in Settings " +
        "(Usage credits balance will be unavailable), or try a different network."

    @Test
    func `Cloudflare challenge preserves cached cookie without browser recovery`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-current-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let replacement = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-should-not-import",
                sourceLabel: "Safari",
                cookieCount: 1)

            do {
                _ = try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(replacement) {
                    try await self.withClaudeWebStub { request in
                        let url = try #require(request.url)
                        if url.path == "/api/organizations" {
                            let response = try #require(HTTPURLResponse(
                                url: url,
                                statusCode: 403,
                                httpVersion: "HTTP/1.1",
                                headerFields: ["cf-mitigated": "challenge"]))
                            return (response, Data("challenge".utf8))
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        try await ClaudeWebAPIFetcher.fetchUsage(
                            browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
                Issue.record("Expected Cloudflare challenge")
            } catch {
                #expect(error.localizedDescription == Self.challengeMessage)
            }

            let cached = CookieHeaderCache.load(provider: .claude)
            #expect(cached != nil)
            #expect(cached?.cookieHeader == "sessionKey=sk-ant-current-token")
            #expect(cached?.sourceLabel == "Chrome")
        }
    }

    @Test
    func `background refresh surfaces original auth error when browser recovery finds nothing`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            await #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
                try await ProviderInteractionContext.$current.withValue(.background) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        // No `ClaudeWebSessionKeyImport.overrideForTesting` is installed, so browser recovery
                        // finds no candidates — mirroring a real background attempt where no browser yields a
                        // session key.
                        _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
            }

            // The stale cache was cleared by the invalidation attempt (matches the Ollama behavior); only the
            // *error surfaced to the caller* is what this test guards.
            #expect(CookieHeaderCache.load(provider: .claude) == nil)
        }
    }

    @Test
    func `background refresh reports an unverified session instead of a sign-out when recovery is skipped`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            // A default-home `BrowserDetection` is deliberately safety-suppressed under tests
            // (`BrowserCookieAccessGate.cookieStoreAccessDecision`), which alone would make every
            // browser "unavailable" regardless of the gate — masking what this test means to exercise.
            // A non-default home (it need not exist on disk; the decision only compares paths) lifts
            // that suppression so Safari genuinely reaches the gate check below.
            let isolatedHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-background-recovery-\(UUID().uuidString)").path

            func attemptOnce() async {
                do {
                    try await BrowserCookieAccessGate.withShouldAttemptOverrideForTesting(false) {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            try await self.withClaudeWebStub { request in
                                let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                                    "sessionKey=sk-ant-stale-token"
                                if request.url?.path == "/api/organizations", isStale {
                                    let url = try #require(request.url)
                                    return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                                }
                                return try Self.response(for: request, setCookie: nil)
                            } operation: {
                                // The gate is forced to skip every browser (as a real inconclusive Keychain
                                // preflight would), rather than a genuine attempt finding no session — the
                                // distinction this fix exists to preserve.
                                _ = try await ClaudeWebAPIFetcher.fetchUsage(
                                    browserDetection: BrowserDetection(homeDirectory: isolatedHome, cacheTTL: 0))
                            }
                        }
                    }
                    Issue.record("Expected cachedSessionUnverifiedInBackground")
                } catch let error as ClaudeWebAPIFetcher.FetchError {
                    guard case .cachedSessionUnverifiedInBackground = error else {
                        Issue.record("Expected cachedSessionUnverifiedInBackground, got \(error)")
                        return
                    }
                } catch {
                    Issue.record("Expected cachedSessionUnverifiedInBackground, got \(error)")
                }
            }

            await attemptOnce()

            // Unlike a confirmed failure, the stale cache is deliberately left in place rather than
            // cleared: this is what lets a *second* consecutive cycle under the same still-inconclusive
            // gate see the same cached entry again below, instead of losing all evidence that a session
            // was ever working and silently regressing to the plain sign-in message.
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-stale-token")

            await attemptOnce()
            #expect(CookieHeaderCache.load(provider: .claude)?.cookieHeader == "sessionKey=sk-ant-stale-token")

            // This is what actually carries the unverified state through the app's Auto source mode:
            // ClaudeWebFetchStrategy.isAvailable short-circuits to `hasSessionKey`'s cache fast path before
            // ever calling `fetch`. Under the old behavior (clearing the cache immediately on invalidation),
            // that fast path would find nothing and fall through to a *second*, unaware extraction attempt
            // that also gets gate-skipped — reporting unavailable and letting the Auto pipeline surface a
            // different (e.g. OAuth) failure instead, so the unverified classification above was never even
            // reached on the next cycle. Leaving the stale-but-structurally-valid cookie in place keeps this
            // fast path (and therefore availability) true, so the real fetch — and this classification —
            // keeps running every cycle.
            #expect(ClaudeWebAPIFetcher.hasSessionKey(browserDetection: BrowserDetection(cacheTTL: 0)))
        }
    }

    @Test
    func `background refresh reports unverified session despite an unrelated empty safari read`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            // A non-default home lifts the test-safety suppression that would otherwise make every
            // browser "unavailable" (masking the gate check this test means to exercise), and a fake
            // Chrome cookie store makes Chrome itself look genuinely installed so it reaches — and is
            // rejected by — the Keychain preflight below, instead of being filtered out earlier as "not
            // installed" the way an unfaked Chrome would be in this isolated home.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-background-recovery-mixed-\(UUID().uuidString)", isDirectory: true)
            let chromeCookies = temp
                .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
            try FileManager.default.createDirectory(
                at: chromeCookies.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: chromeCookies.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: temp) }
            let detection = BrowserDetection(
                homeDirectory: temp.path,
                cacheTTL: 0,
                fileExists: { path in
                    if path == "/Applications/Google Chrome.app" { return true }
                    return FileManager.default.fileExists(atPath: path)
                },
                directoryContents: { path in try? FileManager.default.contentsOfDirectory(atPath: path) })

            do {
                try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        // Every Chromium-family candidate is gated on this and stays inconclusive even
                        // after the bounded retry, so it is skipped. Safari needs no Keychain decryption
                        // at all and bypasses this check entirely (see BrowserCookieAccessGate.shouldAttempt),
                        // so it is still genuinely attempted — and, with no session-key override installed,
                        // comes up empty for real. This is the mixed outcome the fix must not collapse into
                        // "recovery was attempted".
                        .temporarilyUnavailable
                    } operation: {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            try await self.withClaudeWebStub { request in
                                let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                                    "sessionKey=sk-ant-stale-token"
                                if request.url?.path == "/api/organizations", isStale {
                                    let url = try #require(request.url)
                                    return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                                }
                                return try Self.response(for: request, setCookie: nil)
                            } operation: {
                                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: detection)
                            }
                        }
                    }
                }
                Issue.record("Expected cachedSessionUnverifiedInBackground")
            } catch let error as ClaudeWebAPIFetcher.FetchError {
                guard case .cachedSessionUnverifiedInBackground = error else {
                    Issue.record("Expected cachedSessionUnverifiedInBackground, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected cachedSessionUnverifiedInBackground, got \(error)")
            }
        }
    }

    @Test
    func `background refresh still recovers when browser cookie read succeeds without a prompt`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let imported = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-imported-token",
                sourceLabel: "Safari",
                cookieCount: 1)

            try await ProviderInteractionContext.$current.withValue(.background) {
                try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(imported) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        let usage = try await ClaudeWebAPIFetcher.fetchUsage(
                            browserDetection: BrowserDetection(cacheTTL: 0))
                        #expect(usage.sessionPercentUsed == 11)
                    }
                }
            }

            let cached = try #require(CookieHeaderCache.load(provider: .claude))
            #expect(cached.cookieHeader == "sessionKey=sk-ant-imported-token")
            #expect(cached.sourceLabel == "Safari")
        }
    }

    enum RecoveredRequestFailure: CaseIterable, Sendable {
        case timeout, unavailable, challenge, cancelled
    }

    @Test(arguments: RecoveredRequestFailure.allCases)
    func `recovered session failures are not replaced by stale cookie auth errors`(
        _ failure: RecoveredRequestFailure) async
    {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }
            let imported = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-imported-token",
                sourceLabel: "Safari",
                cookieCount: 1)
            let requests = LockIsolated<[String]>([])

            do {
                _ = try await ProviderInteractionContext.$current.withValue(.background) {
                    try await ClaudeWebSessionKeyImport.$overrideForTesting.withValue(imported) {
                        try await self.withClaudeWebStub { request in
                            let url = try #require(request.url)
                            #expect(url.path == "/api/organizations")
                            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                            requests.setValue(requests.value + [cookie])
                            if cookie == "sessionKey=sk-ant-stale-token" {
                                return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                            }
                            #expect(cookie == "sessionKey=sk-ant-imported-token")
                            switch failure {
                            case .timeout: throw URLError(.timedOut)
                            case .cancelled: throw URLError(.cancelled)
                            case .unavailable:
                                return Self.jsonResponse(url: url, body: "{}", statusCode: 503, setCookie: nil)
                            case .challenge:
                                let response = try #require(HTTPURLResponse(
                                    url: url,
                                    statusCode: 403,
                                    httpVersion: nil,
                                    headerFields: ["cf-mitigated": "challenge"]))
                                return (response, Data("challenge".utf8))
                            }
                        } operation: {
                            try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                        }
                    }
                }
                Issue.record("Expected recovered request to fail")
            } catch {
                switch failure {
                case .timeout: #expect((error as? URLError)?.code == .timedOut)
                case .cancelled: #expect((error as? URLError)?.code == .cancelled)
                case .challenge: #expect(error.localizedDescription == Self.challengeMessage)
                case .unavailable:
                    if case let .serverError(code) = error as? ClaudeWebAPIFetcher.FetchError {
                        #expect(code == 503)
                    } else {
                        Issue.record("Expected the recovered request's server error")
                    }
                }
            }
            #expect(requests.value == [
                "sessionKey=sk-ant-stale-token",
                "sessionKey=sk-ant-imported-token",
            ])
        }
    }

    @Test
    func `background refresh with no cached session ever reports no session key found, not unverified`() async throws {
        try await self.withIsolatedCookieCache {
            // No cached cookie at all, and nothing stored beforehand: a first-ever refresh, or a
            // genuinely signed-out account — not a repeat cycle after an earlier invalidation (that case
            // is covered above, where the stale entry is deliberately left in the cache instead of
            // cleared). With no evidence any session was ever working, a gate skip must not be reported as
            // "unverified... showing last-known usage" when no last-known usage exists, and must not
            // suppress the sign-in affordance the way `cachedSessionUnverifiedInBackground` does.

            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-background-recovery-no-cache-\(UUID().uuidString)", isDirectory: true)
            let chromeCookies = temp
                .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
            try FileManager.default.createDirectory(
                at: chromeCookies.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: chromeCookies.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: temp) }
            let detection = BrowserDetection(
                homeDirectory: temp.path,
                cacheTTL: 0,
                fileExists: { path in
                    if path == "/Applications/Google Chrome.app" { return true }
                    return FileManager.default.fileExists(atPath: path)
                },
                directoryContents: { path in try? FileManager.default.contentsOfDirectory(atPath: path) })

            do {
                try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        .temporarilyUnavailable
                    } operation: {
                        try await ProviderInteractionContext.$current.withValue(.background) {
                            try await self.withClaudeWebStub { request in
                                try Self.response(for: request, setCookie: nil)
                            } operation: {
                                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: detection)
                            }
                        }
                    }
                }
                Issue.record("Expected noSessionKeyFound")
            } catch let error as ClaudeWebAPIFetcher.FetchError {
                guard case .noSessionKeyFound = error else {
                    Issue.record("Expected noSessionKeyFound, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected noSessionKeyFound, got \(error)")
            }
        }
    }

    @Test
    func `user initiated refresh does not mask a skipped candidate when another browser was genuinely read`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            // Mirrors the existing "mixed" scenario (Chrome skipped by an inconclusive Keychain preflight,
            // Safari genuinely tried and empty) but under `.userInitiated` instead of `.background`: the
            // explicit-retry scope a user-initiated refresh runs through can permit one browser through its
            // cooldown while a *different* installed Chromium browser is still separately skipped, so
            // `anySkippedByGate` can be true even though the user already completed a real, informative
            // retry. That must never be masked as "unverified... click Refresh to check now" — the user
            // just did, and deserves the confirmed cached-auth error instead.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "claude-background-recovery-user-initiated-\(UUID().uuidString)",
                    isDirectory: true)
            let chromeCookies = temp
                .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
            try FileManager.default.createDirectory(
                at: chromeCookies.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: chromeCookies.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: temp) }
            let detection = BrowserDetection(
                homeDirectory: temp.path,
                cacheTTL: 0,
                fileExists: { path in
                    if path == "/Applications/Google Chrome.app" { return true }
                    return FileManager.default.fileExists(atPath: path)
                },
                directoryContents: { path in try? FileManager.default.contentsOfDirectory(atPath: path) })

            do {
                try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        .temporarilyUnavailable
                    } operation: {
                        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                            try await self.withClaudeWebStub { request in
                                let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                                    "sessionKey=sk-ant-stale-token"
                                if request.url?.path == "/api/organizations", isStale {
                                    let url = try #require(request.url)
                                    return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                                }
                                return try Self.response(for: request, setCookie: nil)
                            } operation: {
                                _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: detection)
                            }
                        }
                    }
                }
                Issue.record("Expected the confirmed cached-auth error to propagate")
            } catch let error as ClaudeWebAPIFetcher.FetchError {
                guard case .unauthorized = error else {
                    Issue.record("Expected .unauthorized, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected .unauthorized, got \(error)")
            }
        }
    }

    @Test
    func `background refresh preserves a confirmed auth failure after a real session is recovered`() async throws {
        try await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            // Same isolated-home + faked-Chrome-install setup as the "mixed" test above, so Chrome
            // genuinely reaches — and is skipped by — the inconclusive Keychain preflight below.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-background-recovery-confirmed-\(UUID().uuidString)", isDirectory: true)
            let chromeCookies = temp
                .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network/Cookies")
            try FileManager.default.createDirectory(
                at: chromeCookies.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: chromeCookies.path, contents: Data())
            defer { try? FileManager.default.removeItem(at: temp) }
            let detection = BrowserDetection(
                homeDirectory: temp.path,
                cacheTTL: 0,
                fileExists: { path in
                    if path == "/Applications/Google Chrome.app" { return true }
                    return FileManager.default.fileExists(atPath: path)
                },
                directoryContents: { path in try? FileManager.default.contentsOfDirectory(atPath: path) })

            // Unlike the "mixed" test, Safari does not come up empty here: a session-key override lets it
            // genuinely recover a session (mirroring a real user who is, in fact, signed in to claude.ai in
            // Safari) — but the API then rejects that recovered cookie with a real 401. That confirmed
            // rejection must propagate as-is, not be swallowed into "unverified" just because Chrome was
            // separately skipped by the gate.
            let recovered = ClaudeWebAPIFetcher.SessionKeyInfo(
                key: "sk-ant-recovered-but-revoked",
                sourceLabel: "Safari",
                cookieCount: 1)

            do {
                try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try await KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        .temporarilyUnavailable
                    } operation: {
                        try await ClaudeWebSessionKeyImport.$browserOverrideForTesting.withValue({ browser in
                            guard browser == .safari else { return nil }
                            return recovered
                        }) {
                            try await ProviderInteractionContext.$current.withValue(.background) {
                                try await self.withClaudeWebStub { request in
                                    // The stale cached cookie must itself be rejected first (mirroring every
                                    // other test in this file) so the code proceeds into invalidation +
                                    // recovery at all; the recovered cookie is then rejected too, simulating
                                    // the confirmed post-recovery auth failure this test guards.
                                    let cookie = request.value(forHTTPHeaderField: "Cookie")
                                    let isStale = cookie == "sessionKey=sk-ant-stale-token"
                                    let isRecoveredCookie = cookie == "sessionKey=sk-ant-recovered-but-revoked"
                                    if request.url?.path == "/api/organizations", isStale || isRecoveredCookie {
                                        let url = try #require(request.url)
                                        return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                                    }
                                    return try Self.response(for: request, setCookie: nil)
                                } operation: {
                                    _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: detection)
                                }
                            }
                        }
                    }
                }
                Issue.record("Expected the confirmed .unauthorized error to propagate")
            } catch let error as ClaudeWebAPIFetcher.FetchError {
                guard case .unauthorized = error else {
                    Issue.record("Expected .unauthorized, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected .unauthorized, got \(error)")
            }

            // The original cached cookie (rejected at the top of this same attempt) is now doubly
            // confirmed dead: a completely different, freshly recovered key also failed auth, so this
            // isn't a gate side effect. That original entry must be cleared too — left in place, a later
            // cycle's gate skip could still reclassify it as merely "unverified" despite this attempt's
            // own confirmed rejection of both keys.
            #expect(CookieHeaderCache.load(provider: .claude) == nil)
        }
    }

    @Test
    func `user initiated refresh surfaces original auth error when browser recovery finds nothing`() async {
        await self.withIsolatedCookieCache {
            CookieHeaderCache.store(
                provider: .claude,
                cookieHeader: "sessionKey=sk-ant-stale-token",
                sourceLabel: "Chrome")
            defer { CookieHeaderCache.clear(provider: .claude) }

            await #expect(throws: ClaudeWebAPIFetcher.FetchError.self) {
                try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                    try await self.withClaudeWebStub { request in
                        let isStale = request.value(forHTTPHeaderField: "Cookie") ==
                            "sessionKey=sk-ant-stale-token"
                        if request.url?.path == "/api/organizations", isStale {
                            let url = try #require(request.url)
                            return Self.jsonResponse(url: url, body: "{}", statusCode: 401, setCookie: nil)
                        }
                        return try Self.response(for: request, setCookie: nil)
                    } operation: {
                        _ = try await ClaudeWebAPIFetcher.fetchUsage(browserDetection: BrowserDetection(cacheTTL: 0))
                    }
                }
            }
        }
    }

    // MARK: - Helpers (mirrors ClaudeWebCookieRenewalTests' stub/cache isolation)

    private func withIsolatedCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        let legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-web-background-recovery-\(UUID().uuidString)", isDirectory: true)
        return try await KeychainCacheStore.withServiceOverrideForTesting(
            "claude-web-background-recovery-\(UUID().uuidString)")
        {
            try await CookieHeaderCache.withLegacyBaseURLOverrideForTesting(legacyBase) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                CookieHeaderCache.resetDisplayCacheForTesting()
                defer { CookieHeaderCache.resetDisplayCacheForTesting() }
                return try await operation()
            }
        }
    }

    private func withClaudeWebStub<T>(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T) async rethrows -> T
    {
        let transport = ProviderHTTPTransportHandler { request in
            let (response, data) = try handler(request)
            return (data, response)
        }
        return try await ClaudeWebHTTPTransport.$overrideForTesting.withValue(transport) {
            try await operation()
        }
    }

    private static func response(
        for request: URLRequest,
        setCookie: String?) throws -> (HTTPURLResponse, Data)
    {
        let url = try #require(request.url)
        switch url.path {
        case "/api/organizations":
            return self.jsonResponse(
                url: url,
                body: #"[{"uuid":"org-123","name":"Test Org","capabilities":["chat"]}]"#,
                setCookie: setCookie)
        case "/api/organizations/org-123/usage":
            return self.jsonResponse(
                url: url,
                body: """
                {
                  "five_hour": { "utilization": 11 },
                  "seven_day": { "utilization": 22 }
                }
                """,
                setCookie: setCookie)
        case "/api/account", "/api/organizations/org-123/overage_spend_limit":
            return self.jsonResponse(url: url, body: "{}", statusCode: 404, setCookie: setCookie)
        default:
            return self.jsonResponse(url: url, body: "{}", statusCode: 404, setCookie: setCookie)
        }
    }

    private static func jsonResponse(
        url: URL,
        body: String,
        statusCode: Int = 200,
        setCookie: String?) -> (HTTPURLResponse, Data)
    {
        var headerFields = ["Content-Type": "application/json"]
        if let setCookie {
            headerFields["Set-Cookie"] = setCookie
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields)!
        return (response, Data(body.utf8))
    }
}
