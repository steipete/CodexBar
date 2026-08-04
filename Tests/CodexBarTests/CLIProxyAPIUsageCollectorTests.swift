import Foundation
import Testing
@testable import CodexBarCore

private actor CLIProxyAPICollectionContinuationProbe {
    private(set) var popCount = 0
    private var continuationCheckCount = 0

    func shouldContinue() -> Bool {
        self.continuationCheckCount += 1
        return self.continuationCheckCount == 1
    }

    func recordPop() {
        self.popCount += 1
    }
}

struct CLIProxyAPIUsageCollectorTests {
    @Test
    func `queue client preserves valid records around a malformed entry`() async throws {
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = ["request-before", "request-after"].map { requestID in
            CLIProxyAPIUsageRecord(
                timestamp: timestamp,
                provider: "codex",
                model: "gpt-5.5",
                alias: "gpt-5.5",
                endpoint: "POST /v1/messages",
                authType: "oauth",
                requestID: requestID,
                tokens: .init(input: 10, output: 20, total: 30))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validObjects = try records.map {
            try JSONSerialization.jsonObject(with: encoder.encode($0))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            validObjects[0],
            ["timestamp": "not-a-date"],
            validObjects[1],
        ])
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })

        let batch = try await client.pop(count: 100)

        #expect(batch.receivedCount == 3)
        #expect(batch.records.map(\.requestID) == ["request-before", "request-after"])
    }

    @Test
    func `persists an idless popped batch outside a failed cache for the next collection`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-blocked-\(UUID().uuidString)", isDirectory: false)
        let pendingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-pending-\(UUID().uuidString)", isDirectory: true)
        try Data("not-a-directory".utf8).write(to: cacheRoot)
        defer {
            try? fileManager.removeItem(at: cacheRoot)
            try? fileManager.removeItem(at: pendingRoot)
        }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.5",
            alias: "gpt-5.5",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "",
            tokens: .init(input: 10, output: 20, total: 30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record])
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: cacheRoot,
            pendingRoot: pendingRoot,
            client: client)

        #expect(result == .failed("Could not save CLIProxyAPI usage telemetry."))
        let pendingOccurrenceID = try #require(
            CLIProxyAPIUsagePendingIO.load(pendingRoot: pendingRoot)?.first?.localOccurrenceID)
        #expect(!pendingOccurrenceID.isEmpty)
        try fileManager.removeItem(at: cacheRoot)
        let retryClient = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.localOccurrenceID) == [
                    pendingOccurrenceID,
                ])
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data("[]".utf8), response)
            })

        let retryResult = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: cacheRoot,
            pendingRoot: pendingRoot,
            client: retryClient)

        #expect(retryResult == .collected(1))
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.localOccurrenceID) == [pendingOccurrenceID])
        #expect(!fileManager.fileExists(
            atPath: CLIProxyAPIUsagePendingIO.pendingFileURL(pendingRoot: pendingRoot).path))
    }

    @Test
    func `does not merge a popped batch when staging fails`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-cache-\(UUID().uuidString)", isDirectory: true)
        let pendingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-blocked-pending-\(UUID().uuidString)", isDirectory: false)
        try Data("not-a-directory".utf8).write(to: pendingRoot)
        defer {
            try? fileManager.removeItem(at: cacheRoot)
            try? fileManager.removeItem(at: pendingRoot)
        }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.5",
            alias: "gpt-5.5",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "request-1",
            tokens: .init(input: 10, output: 20, total: 30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record])
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: cacheRoot,
            pendingRoot: pendingRoot,
            client: client)

        #expect(result == .failed("Could not stage CLIProxyAPI usage telemetry."))
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).isEmpty)
        #expect(!fileManager.fileExists(
            atPath: CLIProxyAPIUsageCacheIO.cacheFileURL(cacheRoot: cacheRoot).path))
    }

    @Test
    func `collector rechecks opt out before every destructive pop`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-opt-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = (0..<100).map { index in
            CLIProxyAPIUsageRecord(
                timestamp: timestamp.addingTimeInterval(TimeInterval(index)),
                provider: "codex",
                model: "gpt-5.5",
                alias: "gpt-5.5",
                endpoint: "POST /v1/messages",
                authType: "oauth",
                requestID: "request-\(index)",
                tokens: .init(input: 10, output: 20, total: 30))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        let probe = CLIProxyAPICollectionContinuationProbe()
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                await probe.recordPop()
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: cacheRoot,
            shouldContinue: {
                await probe.shouldContinue()
            },
            client: client)

        #expect(result == .disabled)
        #expect(await probe.popCount == 1)
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).count == 100)
    }

    @Test
    func `collector rechecks configuration after acquiring the interprocess lock`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxy-queued-disconnect-\(UUID().uuidString)", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cost-usage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let configurationChecked = DispatchSemaphore(value: 0)
        let popProbe = CLIProxyAPICollectionContinuationProbe()
        let lockHolder = Task.detached {
            try await CostUsageCacheLocations.withCLIProxyAPIInterprocessLock(stateRoot: root) {
                lockAcquired.signal()
                _ = await Self.waitForSignal(releaseLock, timeout: .distantFuture)
            }
        }
        #expect(await Self.waitForSignal(lockAcquired, timeout: .now() + 1))
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                await popProbe.recordPop()
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (Data("[]".utf8), response)
            })
        let collection = Task.detached {
            await CLIProxyAPIUsageCollector.collect(
                cacheRoot: cacheRoot,
                configurationIsCurrent: {
                    configurationChecked.signal()
                    return !CostUsageCacheLocations.isCLIProxyAPIExplicitlyDisconnected(stateRoot: root)
                },
                client: client)
        }
        #expect(await Self.waitForSignal(configurationChecked, timeout: .now() + 1))
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(true, stateRoot: root))
        releaseLock.signal()

        try await lockHolder.value
        #expect(await collection.value == .notConfigured)
        #expect(await popProbe.popCount == 0)
    }

    @Test
    func `temporary credential unavailability remains retryable`() async {
        let result = await CLIProxyAPIUsageCollector.collect(
            settingsResult: .temporarilyUnavailable)

        #expect(result == .failed("CLIProxyAPI configuration is temporarily unavailable."))
    }

    @Test
    func `collector rechecks configuration before every destructive pop`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-mid-collection-disconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let records = (0..<100).map { index in
            CLIProxyAPIUsageRecord(
                timestamp: timestamp.addingTimeInterval(TimeInterval(index)),
                provider: "codex",
                model: "gpt-5.5",
                alias: "gpt-5.5",
                endpoint: "POST /v1/messages",
                authType: "oauth",
                requestID: "request-\(index)",
                tokens: .init(input: 10, output: 20, total: 30))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        let configurationIsCurrent = LockIsolated(true)
        let popCount = LockIsolated(0)
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                popCount.setValue(popCount.value + 1)
                configurationIsCurrent.setValue(false)
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })

        let result = await CLIProxyAPIUsageCollector.collect(
            cacheRoot: cacheRoot,
            configurationIsCurrent: { configurationIsCurrent.value },
            client: client)

        #expect(result == .notConfigured)
        #expect(popCount.value == 1)
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).count == 100)
    }

    @Test
    func `collector stages an in flight destructive pop before honoring cancellation`() async throws {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cliproxy-cancelled-pop-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: cacheRoot) }
        let timestamp = try #require(CostUsageDateParser.parse("2026-07-16T12:00:00Z"))
        let record = CLIProxyAPIUsageRecord(
            timestamp: timestamp,
            provider: "codex",
            model: "gpt-5.5",
            alias: "gpt-5.5",
            endpoint: "POST /v1/messages",
            authType: "oauth",
            requestID: "request-in-flight",
            tokens: .init(input: 10, output: 20, total: 30))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record])
        let popStarted = DispatchSemaphore(value: 0)
        let releasePop = DispatchSemaphore(value: 0)
        let client = CLIProxyAPIUsageQueueClient(
            settings: .init(managementKey: "management-secret"),
            dataLoader: { request in
                popStarted.signal()
                _ = await Self.waitForSignal(releasePop, timeout: .distantFuture)
                try Task.checkCancellation()
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (data, response)
            })
        let collection = Task {
            await CLIProxyAPIUsageCollector.collect(
                cacheRoot: cacheRoot,
                client: client)
        }
        #expect(await Self.waitForSignal(popStarted, timeout: .now() + 1))

        collection.cancel()
        releasePop.signal()

        #expect(await collection.value == .collected(1))
        #expect(CLIProxyAPIUsageCacheIO.load(cacheRoot: cacheRoot).map(\.requestID) == ["request-in-flight"])
    }

    private static func waitForSignal(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime) async -> Bool
    {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }
}
