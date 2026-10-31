import Foundation
import Testing
@testable import CodexBarCore

/// Nested so the global BedrockStubURLProtocol handler is never shared across concurrently running suites.
extension BedrockUsageStatsTests {
    @Suite
    struct BedrockCostExplorerCacheTests {
        private static let env: [String: String] = [BedrockSettingsReader.apiURLKey: "https://bedrock.test"]
        private static let now = Date(timeIntervalSince1970: 1_791_849_600)
        private static let body = #"""
        {"ResultsByTime":[{"TimePeriod":{"Start":"2026-10-01"},"Groups":[{"Keys":["Amazon Bedrock"],
          "Metrics":{"UnblendedCost":{"Amount":"12.50","Unit":"USD"}}}]}]}
        """#

        private static func credentials(_ id: String = "AKIATEST") -> BedrockAWSSigner.Credentials {
            BedrockAWSSigner.Credentials(accessKeyID: id, secretAccessKey: "testSecret", sessionToken: nil)
        }

        private static func tempCache() -> (BedrockCostExplorerCache, URL) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bedrock-ce-cache-\(UUID().uuidString)/cache.json")
            return (BedrockCostExplorerCache(fileURL: url), url)
        }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.value
            }

            func increment() {
                self.lock.lock()
                self.value += 1
                self.lock.unlock()
            }
        }

        private static func install(counter: Counter) -> Bool {
            let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
            BedrockStubURLProtocol.handler = { request in
                counter.increment()
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (response, Data(Self.body.utf8))
            }
            return registered
        }

        private static func uninstall(_ registered: Bool) {
            if registered { URLProtocol.unregisterClass(BedrockStubURLProtocol.self) }
            BedrockStubURLProtocol.handler = nil
        }

        private static func spend(
            _ cache: BedrockCostExplorerCache,
            credentials: BedrockAWSSigner.Credentials = credentials(),
            environment: [String: String] = env,
            now: Date = now) async throws -> Double
        {
            try await BedrockUsageFetcher.fetchUsage(
                credentials: credentials,
                region: "us-east-1",
                budget: nil,
                environment: environment,
                now: now,
                costCache: cache).monthlySpend
        }

        @Test
        func `second fetch within the interval is served from cache`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(try await Self.spend(cache) == 12.5)
            #expect(try await Self.spend(cache, now: Self.now.addingTimeInterval(5 * 3600)) == 12.5)
            #expect(counter.count == 1)
        }

        @Test
        func `fetch after the interval queries again`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = try await Self.spend(cache)
            _ = try await Self.spend(cache, now: Self.now.addingTimeInterval(6 * 3600 + 1))
            #expect(counter.count == 2)
        }

        @Test
        func `configured interval and zero disable are honored`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            var short = Self.env
            short[BedrockCostExplorerCache.intervalHoursKey] = "1"
            _ = try await Self.spend(cache, environment: short)
            _ = try await Self.spend(cache, environment: short, now: Self.now.addingTimeInterval(1800))
            #expect(counter.count == 1)
            _ = try await Self.spend(cache, environment: short, now: Self.now.addingTimeInterval(3601))
            #expect(counter.count == 2)

            var off = Self.env
            off[BedrockCostExplorerCache.intervalHoursKey] = "0"
            _ = try await Self.spend(cache, environment: off)
            _ = try await Self.spend(cache, environment: off)
            #expect(counter.count == 4)
        }

        @Test
        func `a different access key does not reuse the cached response`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = try await Self.spend(cache, credentials: Self.credentials("AKIAONE"))
            _ = try await Self.spend(cache, credentials: Self.credentials("AKIATWO"))
            #expect(counter.count == 2)
            _ = try await Self.spend(cache, credentials: Self.credentials("AKIATWO"))
            #expect(counter.count == 2)
        }

        @Test
        func `profile identity survives credential rotation but not a profile change`() {
            let profileA = [BedrockSettingsReader.profileKey: "a", BedrockSettingsReader.authModeKey: "profile"]
            let profileB = [BedrockSettingsReader.profileKey: "b", BedrockSettingsReader.authModeKey: "profile"]
            let first = BedrockCostExplorerCache.identity(
                credentials: Self.credentials("ASIAONE"),
                environment: profileA)
            let rotated = BedrockCostExplorerCache.identity(
                credentials: Self.credentials("ASIATWO"),
                environment: profileA)
            let other = BedrockCostExplorerCache.identity(
                credentials: Self.credentials("ASIAONE"),
                environment: profileB)
            #expect(first == rotated)
            #expect(first != other)
        }

        @Test
        func `cache survives a new instance on the same file`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = try await Self.spend(cache)
            let relaunched = BedrockCostExplorerCache(fileURL: url)
            #expect(try await Self.spend(relaunched, now: Self.now.addingTimeInterval(3600)) == 12.5)
            #expect(counter.count == 1)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }

        @Test
        func `user initiated refresh bypasses the cache and updates it`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            _ = try await Self.spend(cache)
            _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await Self.spend(cache, now: Self.now.addingTimeInterval(60))
            }
            #expect(counter.count == 2)
            _ = try await Self.spend(cache, now: Self.now.addingTimeInterval(3600))
            #expect(counter.count == 2)
        }

        @Test
        func `daily report and monthly spend are cached independently`() async throws {
            let counter = Counter()
            let registered = Self.install(counter: counter)
            defer { Self.uninstall(registered) }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            for _ in 0..<3 {
                _ = try await Self.spend(cache)
                _ = try await BedrockUsageFetcher.fetchDailyReport(
                    credentials: Self.credentials(),
                    since: Self.now.addingTimeInterval(-86400),
                    until: Self.now,
                    environment: Self.env,
                    costCache: cache,
                    now: Self.now)
            }
            #expect(counter.count == 2)
        }

        @Test
        func `failed queries are not cached`() async throws {
            let registered = URLProtocol.registerClass(BedrockStubURLProtocol.self)
            defer { Self.uninstall(registered) }
            BedrockStubURLProtocol.handler = { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil))
                return (response, Data("{}".utf8))
            }
            let (cache, url) = Self.tempCache()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            await #expect(throws: (any Error).self) { try await Self.spend(cache) }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }

        @Test
        func `profile identity changes with the AWS config file and the interval is capped`() {
            let base = [BedrockSettingsReader.profileKey: "a", BedrockSettingsReader.authModeKey: "profile"]
            var other = base
            other["AWS_CONFIG_FILE"] = "/tmp/other-config"
            let creds = Self.credentials()
            #expect(BedrockCostExplorerCache.identity(credentials: creds, environment: base) !=
                BedrockCostExplorerCache.identity(credentials: creds, environment: other))
            let huge = [BedrockCostExplorerCache.intervalHoursKey: "1e306"]
            #expect(BedrockCostExplorerCache.interval(environment: huge) == 48 * 3600)
            #expect(BedrockCostExplorerCache.interval(environment: [:]) == 6 * 3600)
        }
    }
}
