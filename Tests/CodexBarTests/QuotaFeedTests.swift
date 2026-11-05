import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import CodexBarCore

struct QuotaFeedTests {
    private let now = Date(timeIntervalSince1970: 1_767_268_800)

    private func data(_ changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "version": 1, "observedAt": "2026-01-01T12:00:00Z", "used": 25, "limit": 100,
        ]
        object.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func `maps quota without inventing money identity or a reset`() throws {
        let snapshot = try QuotaFeedSnapshot.decode(self.data(), now: self.now).usageSnapshot()
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.primary?.windowMinutes == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.identity == nil)
        #expect(snapshot.updatedAt == self.now)
        #expect(snapshot.details[0].rows.last?.value == "75.00")
    }

    @Test func `maps currency overage and actual observation time`() throws {
        let snapshot = try QuotaFeedSnapshot.decode(
            self.data(["used": 125, "currency": "USD", "resetsAt": "2026-02-01T00:00:00Z"]),
            now: self.now.addingTimeInterval(600)).usageSnapshot()
        #expect(snapshot.primary?.usedPercent == 125)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.used == 125)
        #expect(snapshot.details[0].rows.last?.value == "-25.00 USD")
        #expect(snapshot.updatedAt == self.now)
        #expect(snapshot.providerCost?.updatedAt == self.now)
    }

    @Test func `zero allocation is not a measured percentage`() throws {
        let snapshot = try QuotaFeedSnapshot.decode(
            self.data(["used": 0, "limit": 0]), now: self.now).usageSnapshot()
        #expect(snapshot.primary == nil)
        #expect(snapshot.details[0].rows.last?.value == "0.00")
    }

    @Test(arguments: [-1.0, 901.0])
    func `rejects future and stale source timestamps`(offset: Double) throws {
        let time = offset < 0 ? self.now.addingTimeInterval(-61) : self.now.addingTimeInterval(offset)
        #expect(throws: QuotaFeedError.staleData) {
            try QuotaFeedSnapshot.decode(self.data(), now: time)
        }
    }

    @Test func `rejects an expired reset even when observation is recent`() throws {
        #expect(throws: QuotaFeedError.staleData) {
            try QuotaFeedSnapshot.decode(self.data(["resetsAt": "2026-01-01T12:00:00Z"]), now: self.now)
        }
    }

    @Test func `accepts freshness boundary without rewriting source time`() throws {
        let snapshot = try QuotaFeedSnapshot.decode(self.data(), now: self.now.addingTimeInterval(900))
        #expect(snapshot.observedAt == self.now)
    }

    @Test func `rejects bad numbers versions extra fields and types`() throws {
        let cases: [[String: Any]] = [
            ["used": -1], ["limit": -1], ["version": 2], ["used": "25"],
            ["used": true], ["currency": "usd"], ["currency": "USDD"], ["currency": "USD\n"],
            ["observedAt": "invalid"], ["cookie": "synthetic-value"],
            ["used": 1e308, "limit": 1e-308],
        ]
        for changes in cases {
            #expect(throws: QuotaFeedError.invalidData) {
                try QuotaFeedSnapshot.decode(self.data(changes), now: self.now)
            }
        }
        #expect(throws: QuotaFeedError.invalidData) {
            try QuotaFeedSnapshot.decode(Data("{".utf8), now: self.now)
        }
        #expect(throws: QuotaFeedError.invalidData) {
            try QuotaFeedSnapshot.decode(Data(repeating: 32, count: QuotaFeedSnapshot.maximumBytes + 1), now: self.now)
        }
    }

    @Test func `requires explicit absolute path and does not call the reader for missing paths`() throws {
        let reader = QuotaFeedReader(readFile: { _, _ in
            Issue.record("Unexpected file access")
            return Data()
        })
        for path in [nil, "", "relative.json", "~/quota.json", "https://example.invalid/quota.json"] {
            #expect(throws: QuotaFeedError.missingPath) { try reader.fetch(path: path, now: self.now) }
        }
    }

    @Test func `uses bounded injected reader and redacts file errors`() throws {
        let data = try self.data()
        let reader = QuotaFeedReader(readFile: { path, maximum in
            #expect(path == "/synthetic/quota.json")
            #expect(maximum == 65536)
            return data
        })
        #expect(try reader.fetch(path: "/synthetic/quota.json", now: self.now).primary?.usedPercent == 25)
        let failing = QuotaFeedReader(readFile: { _, _ in
            throw NSError(domain: "synthetic-private-path", code: 1)
        })
        #expect(throws: QuotaFeedError.unreadableFile) {
            try failing.fetch(path: "/synthetic/quota.json", now: self.now)
        }
        #expect(!QuotaFeedError.unreadableFile.localizedDescription.contains("synthetic-private-path"))
    }

    @Test func `host reader rejects symlinks directories oversized and missing files`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("quota.json")
        let link = directory.appendingPathComponent("link.json")
        let fifo = directory.appendingPathComponent("feed.pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let contents = try self.data()
        try contents.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try BoundedLocalFileReader.read(path: file.path, maximumBytes: 65536) == contents)
        for path in [link.path, fifo.path, directory.path, directory.appendingPathComponent("missing").path] {
            #expect(throws: (any Error).self) { try BoundedLocalFileReader.read(path: path, maximumBytes: 65536) }
        }
        #expect(throws: (any Error).self) { try BoundedLocalFileReader.read(path: file.path, maximumBytes: 1) }
    }

    @Test func `config round trip projects the selected file into runtime settings`() throws {
        var config = ProviderConfig(id: .quotafeed, enabled: true)
        config.quotaFeedPath = "/synthetic/quota.json"
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.quotaFeedPath == config.quotaFeedPath)
        let synced = try JSONEncoder().encode(ProviderIntentPayload(config: config))
        let syncJSON = try #require(String(data: synced, encoding: .utf8))
        #expect(!syncJSON.contains("quotaFeedPath"))
        #expect(!syncJSON.contains("/synthetic/"))
        let descriptor = QuotaFeedProviderDescriptor.descriptor
        let contribution = try #require(descriptor.settingsSection.credentialContribution(
            context: ProviderCredentialSettingsContext(config: decoded, account: nil)))
        let settings = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(settings[QuotaFeedProviderSettingsKey.self]?.path == config.quotaFeedPath)
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.metadata.dashboardURL == nil)
        #expect(descriptor.credentials == nil)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .cli])
    }

    @Test func `strategy requires explicit configuration and never falls back to an account`() async {
        let strategy = QuotaFeedFetchStrategy()
        #expect(await !strategy.isAvailable(self.context(path: nil)))
        #expect(await strategy.isAvailable(self.context(path: "/synthetic/quota.json")))
        #expect(!strategy.shouldFallback(on: QuotaFeedError.invalidData, context: self.context(path: nil)))
    }

    @Test func `strategy publishes the configured feed using the local source label`() async throws {
        let data = try self.data(["observedAt": ISO8601DateFormatter().string(from: Date())])
        let strategy = QuotaFeedFetchStrategy(reader: QuotaFeedReader(readFile: { path, _ in
            #expect(path == "/synthetic/quota.json")
            return data
        }))
        let result = try await strategy.fetch(self.context(path: "/synthetic/quota.json"))
        #expect(result.usage.primary?.usedPercent == 25)
        #expect(result.sourceLabel == "local file")
    }

    private func context(path: String?) -> ProviderFetchContext {
        let browsers = BrowserDetection()
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .cli,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: ProviderSettingsSnapshot(
                QuotaFeedProviderSettings(path: path),
                for: QuotaFeedProviderSettingsKey.self),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browsers),
            browserDetection: browsers)
    }
}
