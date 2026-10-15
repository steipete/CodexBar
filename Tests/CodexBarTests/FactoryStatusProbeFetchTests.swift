import Foundation
import Testing
@testable import CodexBarCore
#if os(macOS)
import SQLite3
import SweetCookieKit
#endif

@Suite(.serialized)
struct FactoryStatusProbeFetchTests {
    @Test
    func `keeps stored Factory cookies available when cached header is not logged in`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.host == "app.factory.ai",
               url.path == "/api/app/auth/me",
               request.value(forHTTPHeaderField: "Cookie")?.contains("stale-cache") == true
            {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            if url.host == "api.factory.ai", url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "standard": {
                      "userTokens": 100,
                      "totalAllowance": 1000
                    }
                  },
                  "userId": "user-1"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let cookie = try #require(HTTPCookie(properties: [
            .domain: "app.factory.ai",
            .path: "/",
            .name: "session",
            .value: "valid-session",
        ]))

        let sessionFile = try await Self.isolateFactorySessionStore()
        defer {
            try? FileManager.default.removeItem(at: sessionFile)
        }

        await FactorySessionStore.shared.clearSession()
        CookieHeaderCache.store(provider: .factory, cookieHeader: "session=stale-cache", sourceLabel: "Chrome")
        await FactorySessionStore.shared.setCookies([cookie])
        await FactorySessionStore.shared.resetInMemoryForTesting()
        defer {
            CookieHeaderCache.clear(provider: .factory)
        }

        let probe = FactoryStatusProbe(
            timeout: 1.0,
            browserDetection: BrowserDetection(
                homeDirectory: "/tmp/codexbar-empty-browser-home",
                cacheTTL: 0,
                fileExists: { _ in false },
                directoryContents: { _ in nil }),
            transport: FactoryStubTransport())

        let snapshot = try await probe.fetch()

        #expect(CookieHeaderCache.load(provider: .factory) == nil)
        #expect(snapshot.userId == "user-1")
        #expect(await FactorySessionStore.shared.getCookies().map(\.value) == ["valid-session"])
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
            "GET api.factory.ai/api/organization/subscription/usage?useCache=true",
        ])
        await FactorySessionStore.shared.clearSession()
    }

    @Test
    func `preserves stored Factory refresh token when stored cookies are not logged in`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.host == "app.factory.ai", url.path == "/api/app/auth/me" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            if url.host == "api.factory.ai",
               url.path == "/api/app/auth/me",
               request.value(forHTTPHeaderField: "Cookie")?.contains("stale-session") == true
            {
                return Self.makeResponse(url: url, body: "{}", statusCode: 401)
            }
            if url.host == "api.workos.com", url.path == "/user_management/authenticate" {
                let requestBody = try Self.requestJSONBody(from: request)
                guard requestBody["refresh_token"] as? String == "stale-refresh" else {
                    throw URLError(.userAuthenticationRequired)
                }
                let body = """
                {
                  "access_token": "fresh-access",
                  "refresh_token": "fresh-refresh"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "standard": {
                      "userTokens": 100,
                      "totalAllowance": 1000
                    }
                  },
                  "userId": "user-1"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let cookie = try #require(HTTPCookie(properties: [
            .domain: "app.factory.ai",
            .path: "/",
            .name: "session",
            .value: "stale-session",
        ]))

        let sessionFile = try await Self.isolateFactorySessionStore()
        defer {
            try? FileManager.default.removeItem(at: sessionFile)
        }

        await FactorySessionStore.shared.clearSession()
        CookieHeaderCache.store(provider: .factory, cookieHeader: "session=stale-cache", sourceLabel: "Chrome")
        await FactorySessionStore.shared.setCookies([cookie])
        await FactorySessionStore.shared.setRefreshToken("stale-refresh")
        await FactorySessionStore.shared.resetInMemoryForTesting()
        defer {
            CookieHeaderCache.clear(provider: .factory)
        }

        let probe = FactoryStatusProbe(
            timeout: 1.0,
            browserDetection: BrowserDetection(
                homeDirectory: "/tmp/codexbar-empty-browser-home",
                cacheTTL: 0,
                fileExists: { _ in false },
                directoryContents: { _ in nil }),
            transport: FactoryStubTransport())

        let snapshot = try await probe.fetch()

        #expect(CookieHeaderCache.load(provider: .factory) == nil)
        #expect(snapshot.userId == "user-1")
        #expect(await FactorySessionStore.shared.getCookies().isEmpty)
        #expect(await FactorySessionStore.shared.getBearerToken() == "fresh-access")
        #expect(await FactorySessionStore.shared.getRefreshToken() == "fresh-refresh")
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/app/auth/me",
            "GET app.factory.ai/api/app/auth/me",
            "POST api.workos.com/user_management/authenticate",
            "GET api.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
            "GET api.factory.ai/api/organization/subscription/usage?useCache=true",
        ])
        await FactorySessionStore.shared.clearSession()
    }

    @Test
    func `fetches snapshot using cookie header override`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let path = url.path
            if path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "startDate": 1700000000000,
                    "endDate": 1700003600000,
                    "standard": {
                      "userTokens": 100,
                      "orgTotalTokensUsed": 250,
                      "totalAllowance": 1000,
                      "usedRatio": 0.10
                    },
                    "premium": {
                      "userTokens": 10,
                      "orgTotalTokensUsed": 20,
                      "totalAllowance": 100,
                      "usedRatio": 0.10
                    }
                  },
                  "userId": "user-1"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=test.jwt.token; session=abc")

        #expect(snapshot.standardUserTokens == 100)
        #expect(snapshot.standardAllowance == 1000)
        #expect(snapshot.standardUsedRatio == 0.10)
        #expect(snapshot.premiumUserTokens == 10)
        #expect(snapshot.premiumUsedRatio == 0.10)
        #expect(snapshot.userId == "user-1")
        #expect(snapshot.planName == "Team")

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 10)
        #expect(usage.secondary?.usedPercent == 10)
    }

    @Test
    func `uses bearer subject when auth profile omits user id`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  },
                  "userProfile": {
                    "email": "user@example.com",
                    "role": "member"
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/billing/limits" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
            if url.path == "/api/organization/subscription/usage" {
                guard URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .contains(where: { $0.name == "userId" && $0.value == "user_jwt" }) == true
                else {
                    return Self.makeResponse(
                        url: url,
                        body: #"{"detail":"Must be manager to get usage for other users"}"#,
                        statusCode: 403)
                }
                let body = """
                {
                  "usage": {
                    "standard": {
                      "userTokens": 100,
                      "totalAllowance": 1000,
                      "usedRatio": 0.10
                    }
                  },
                  "userId": "user_jwt"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let token = Self.makeJWT(payload: ["sub": "user_jwt"])
        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=\(token); session=abc")

        #expect(snapshot.userId == "user_jwt")
        #expect(snapshot.standardUserTokens == 100)
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
            "GET app.factory.ai/api/organization/subscription/usage?useCache=true&userId=user_jwt",
        ])
    }

    @Test
    func `falls back to legacy usage when billing limits request fails`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/billing/limits" {
                throw URLError(.timedOut)
            }
            if url.path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "standard": {
                      "userTokens": 100,
                      "totalAllowance": 1000,
                      "usedRatio": 0.10
                    },
                    "premium": {
                      "userTokens": 20,
                      "totalAllowance": 100,
                      "usedRatio": 0.20
                    }
                  },
                  "userId": "user-1"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=test.jwt.token; session=abc")
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.tokenRateLimits == nil)
        #expect(usage.primary?.usedPercent == 10)
        #expect(usage.secondary?.usedPercent == 20)
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
            "GET app.factory.ai/api/organization/subscription/usage?useCache=true",
        ])
    }

    @Test
    func `falls back to legacy usage when billing limits rejects auth`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/billing/limits" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 403)
            }
            if url.path == "/api/organization/subscription/usage" {
                let body = """
                {
                  "usage": {
                    "standard": {
                      "userTokens": 100,
                      "totalAllowance": 1000,
                      "usedRatio": 0.10
                    },
                    "premium": {
                      "userTokens": 20,
                      "totalAllowance": 100,
                      "usedRatio": 0.20
                    }
                  },
                  "userId": "user-1"
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=test.jwt.token; session=abc")
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.tokenRateLimits == nil)
        #expect(usage.primary?.usedPercent == 10)
        #expect(usage.secondary?.usedPercent == 20)
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
            "GET app.factory.ai/api/organization/subscription/usage?useCache=true",
        ])
    }

    @Test
    func `uses token rate limits billing when core pool is absent`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/billing/limits" {
                let body = """
                {
                  "usesTokenRateLimitsBilling": true,
                  "extraUsageBalanceCents": 2500,
                  "overagePreference": null,
                  "extraUsageAllowed": false,
                  "tokenRateLimitsRolloutEligible": true,
                  "limits": {
                    "standard": {
                      "fiveHour": { "usedPercent": 12, "secondsRemaining": 3600 },
                      "weekly": { "usedPercent": 34, "secondsRemaining": 7200 },
                      "monthly": { "usedPercent": 56, "secondsRemaining": 10800 }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.path == "/api/organization/subscription/usage" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 500)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=test.jwt.token; session=abc")
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.tokenRateLimits != nil)
        #expect(usage.primary?.usedPercent == 12)
        #expect(usage.secondary?.usedPercent == 34)
        #expect(usage.tertiary?.usedPercent == 56)
        #expect(usage.extraRateWindows == nil)
        #expect(usage.providerCost?.used == 25)
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
        ])
    }

    @Test
    func `uses token rate limits billing when enabled`() async throws {
        let registered = URLProtocol.registerClass(FactoryStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(FactoryStubURLProtocol.self)
            }
            FactoryStubURLProtocol.handler = nil
            FactoryStubURLProtocol.requests = []
        }
        FactoryStubURLProtocol.requests = []

        FactoryStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/api/app/auth/me" {
                let body = """
                {
                  "organization": {
                    "id": "org_1",
                    "name": "Acme",
                    "subscription": {
                      "factoryTier": "team",
                      "orbSubscription": {
                        "plan": { "name": "Team", "id": "plan_1" },
                        "status": "active"
                      }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.host == "api.factory.ai", url.path == "/api/billing/limits" {
                let body = """
                {
                  "usesTokenRateLimitsBilling": true,
                  "extraUsageBalanceCents": 2500,
                  "overagePreference": "core",
                  "extraUsageAllowed": true,
                  "tokenRateLimitsRolloutEligible": true,
                  "limits": {
                    "standard": {
                      "fiveHour": { "usedPercent": 12, "secondsRemaining": 3600 },
                      "weekly": { "usedPercent": 34, "secondsRemaining": 7200 },
                      "monthly": { "usedPercent": 56, "secondsRemaining": 10800 }
                    },
                    "core": {
                      "fiveHour": { "usedPercent": 7, "secondsRemaining": 1800 },
                      "weekly": { "usedPercent": 8, "secondsRemaining": 2800 },
                      "monthly": { "usedPercent": 9, "secondsRemaining": 3800 }
                    }
                  }
                }
                """
                return Self.makeResponse(url: url, body: body)
            }
            if url.path == "/api/organization/subscription/usage" {
                return Self.makeResponse(url: url, body: "{}", statusCode: 500)
            }
            return Self.makeResponse(url: url, body: "{}", statusCode: 404)
        }

        let probe = FactoryStatusProbe(browserDetection: BrowserDetection(cacheTTL: 0))
        let snapshot = try await probe.fetch(cookieHeaderOverride: "access-token=test.jwt.token; session=abc")
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.tokenRateLimits != nil)
        #expect(usage.primary?.usedPercent == 12)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 34)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 56)
        #expect(usage.extraRateWindows?.map(\.id) == ["factory-core-5h", "factory-core-7d", "factory-core-monthly"])
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 7)
        #expect(usage.providerCost?.used == 25)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.loginMethod(for: .factory) == "Factory Team - Team - Fallback: core")
        #expect(Self.requestTrace() == [
            "GET app.factory.ai/api/app/auth/me",
            "GET api.factory.ai/api/billing/limits",
        ])
    }

    #if os(macOS)
    /// A channel-owned Firefox profile rejected under `.firefox` must not abort the loop before
    /// the channel-specific sources run.
    @Test(arguments: [
        (Browser.firefoxBeta, "firefox-beta", "abc.default-beta"),
        (Browser.firefoxDeveloperEdition, "firefox-dev", "abc.dev-edition-default"),
        (Browser.firefoxNightly, "firefox-nightly", "abc.default-nightly"),
    ])
    func `browser cookie fallback reaches Firefox release channels`(
        browser: Browser,
        remotingName: String,
        profile: String) async throws
    {
        KeychainCacheStore.setTestStoreForTesting(true)
        CookieHeaderCache.clear(provider: .factory)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-deved-home-\(UUID().uuidString)", isDirectory: true)
        let appResources = home
            .appendingPathComponent(
                "Applications/\(browser.appBundleName).app/Contents/Resources",
                isDirectory: true)
        let profileDir = home
            .appendingPathComponent(
                "Library/Application Support/Firefox/Profiles/\(profile)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: appResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try "[App]\nRemotingName=\(remotingName)\n".write(
            to: appResources.appendingPathComponent("application.ini"),
            atomically: true,
            encoding: .utf8)
        try """
        [Compatibility]
        LastVersion=1
        LastOSABI=Darwin_aarch64-gcc3
        LastPlatformDir=\(appResources.path)
        LastAppDir=\(appResources.path)/browser

        """.write(
            to: profileDir.appendingPathComponent("compatibility.ini"),
            atomically: true,
            encoding: .utf8)
        try writeGeckoCookies(
            at: profileDir.appendingPathComponent("cookies.sqlite"),
            host: "app.factory.ai",
            name: "session",
            value: "gecko-channel-session")

        let sessionFile = try await Self.isolateFactorySessionStore()
        defer { try? FileManager.default.removeItem(at: sessionFile) }
        await FactorySessionStore.shared.clearSession()
        defer { CookieHeaderCache.clear(provider: .factory) }

        var logLines: [String] = []
        let detection = BrowserDetection(
            homeDirectory: home.path,
            cacheTTL: 0,
            now: Date.init,
            fileExists: { $0.hasPrefix(home.path) && FileManager.default.fileExists(atPath: $0) },
            directoryContents: { path in
                guard path.hasPrefix(home.path) else { return nil }
                return try? FileManager.default.contentsOfDirectory(atPath: path)
            },
            applicationURLs: { _ in [] },
            profileAccessIssue: { _ in nil })
        let probe = FactoryStatusProbe(
            timeout: 1.0, browserDetection: detection, transport: ChannelFallbackStubTransport())

        let client = BrowserCookieClient(configuration: .init(homeDirectories: [home]))
        let snapshot = try await FactoryCookieImporter.$cookieClient.withValue(client) {
            #expect(FactoryCookieImporter.hasSession(browserDetection: detection))
            let missing = BrowserDetection(
                homeDirectory: home.appendingPathComponent("empty").path,
                cacheTTL: 0,
                now: Date.init,
                fileExists: { _ in false },
                directoryContents: { _ in nil },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil })
            #expect(!FactoryCookieImporter.hasSession(browserDetection: missing))
            return try await FactoryLocalStorageImporter.$safariWebsiteDataRoot.withValue(
                home.appendingPathComponent("empty-safari-store"))
            {
                try await probe.fetch(logger: { logLines.append($0) })
            }
        }

        #expect(snapshot.userId == "user-1")
        let channelHit = logLines.firstIndex { $0.contains("Using cookies from \(browser.displayName)") }
        #expect(channelHit != nil)
        if browser == .firefoxDeveloperEdition {
            let failure = try #require(logLines.firstIndex { $0.contains("Firefox cookie import failed") })
            #expect(failure < (channelHit ?? 0))
        }
        await FactorySessionStore.shared.clearSession()
    }
    #endif

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func makeJWT(payload: [String: Any]) -> String {
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        let header = ["alg": "none", "typ": "JWT"]
        let headerData = (try? JSONSerialization.data(withJSONObject: header)) ?? Data()
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return "\(base64URL(headerData)).\(base64URL(payloadData))."
    }

    private static func requestTrace() -> [String] {
        FactoryStubURLProtocol.requests.compactMap { request in
            guard let url = request.url else { return nil }
            let query = url.query.map { "?\($0)" } ?? ""
            return "\(request.httpMethod ?? "?") \(url.host ?? "unknown")\(url.path)\(query)"
        }
    }

    private static func isolateFactorySessionStore() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-factory-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json")
        await FactorySessionStore.shared.useFileURLForTesting(fileURL)
        return fileURL
    }

    private static func requestJSONBody(from request: URLRequest) throws -> [String: Any] {
        let data = try self.requestBodyData(from: request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw URLError(.badServerResponse)
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class FactoryStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    nonisolated(unsafe) static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.hasSuffix("factory.ai") || host == "api.workos.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            Self.requests.append(self.request)
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct FactoryStubTransport: ProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let handler = FactoryStubURLProtocol.handler else {
            throw URLError(.badServerResponse)
        }
        FactoryStubURLProtocol.requests.append(request)
        let (response, data) = try handler(request)
        return (data, response)
    }
}

#if os(macOS)
private func writeGeckoCookies(
    at url: URL,
    host: String,
    name: String,
    value: String) throws
{
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw URLError(.cannotCreateFile)
    }
    defer { sqlite3_close(db) }
    let statements = [
        """
        CREATE TABLE moz_cookies (
            host TEXT, name TEXT, path TEXT, value TEXT,
            expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER
        )
        """,
        "INSERT INTO moz_cookies VALUES ('\(host)', '\(name)', '/', '\(value)', 1893456000, 1, 1)",
    ]
    for sql in statements {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw URLError(.cannotCreateFile)
        }
    }
}

private struct ChannelFallbackStubTransport: ProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Cookie")?.contains("session=gecko-channel-session") == true
        else { throw URLError(.badServerResponse) }
        let body = switch (url.host, url.path) {
        case (_, "/api/app/auth/me"):
            """
            {"organization": {"id": "org_1", "name": "Acme", "subscription": {
              "factoryTier": "team",
              "orbSubscription": {"plan": {"name": "Team", "id": "plan_1"}, "status": "active"}}}}
            """
        case ("api.factory.ai", "/api/organization/subscription/usage"):
            """
            {"usage": {"standard": {"userTokens": 100, "totalAllowance": 1000}}, "userId": "user-1"}
            """
        default:
            "{}"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: url.path == "/api/billing/limits" ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
#endif
