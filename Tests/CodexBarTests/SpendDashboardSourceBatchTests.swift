import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct SpendDashboardSourceBatchTests {
    @Test(CodexCredentialFixtures(), arguments: [3, 4, 5, 7], [false, true])
    func `bounded Codex batches retain every result in account order`(count: Int, reverse: Bool) async throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent("batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = try (0..<count).map { try Self.makeAccount(id: String($0), root: root) }
        let tracker = SpendDashboardBatchTracker(count: count, reverse: reverse)
        let snapshot = Self.makeSnapshot()
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: accounts.map { "\($0.id)|\($0.cacheIdentity)" }),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: accounts,
            now: snapshot.updatedAt,
            force: true)
        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { context in
                try await tracker.load(index: Int(context.account.id)!)
                return snapshot
            },
            codexActivityLoader: { _ in nil })
        #expect(result.inputs.map(\.id) == accounts.map { "codex:\($0.id)" })
        #expect(result.failedSourceIDs.isEmpty)
        #expect(result.invalidatedSourceIDs.isEmpty)
        #expect(await tracker.peak <= 3)
        #expect(await tracker.completed == count)
    }

    @Test(CodexCredentialFixtures())
    func `a failed throttled account is reported and every successful sibling survives`() async throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent("failed-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = try (0..<7).map { try Self.makeAccount(id: String($0), root: root) }
        let snapshot = Self.makeSnapshot()
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: accounts.map { "\($0.id)|\($0.cacheIdentity)" }),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: accounts,
            now: snapshot.updatedAt,
            force: true)
        let result = await SpendDashboardSource.load(
            request,
            codexSnapshotLoader: { context in
                if context.account.id == "0" {
                    throw SpendDashboardSyntheticError.failed
                }
                return snapshot
            },
            codexActivityLoader: { _ in nil })
        #expect(result.inputs.map(\.id) == (1..<7).map { "codex:\($0)" })
        #expect(result.failedSourceIDs == ["codex:0"])
        #expect(result.invalidatedSourceIDs.isEmpty)
    }

    @Test(CodexCredentialFixtures())
    func `a throttled account whose owner changes cannot publish old private rows`() async throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent("owner-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = try (0..<7).map { try Self.makeAccount(id: String($0), root: root) }
        let snapshot = Self.makeSnapshot()
        let result = await SpendDashboardSource.load(
            Self.request(accounts: accounts, now: snapshot.updatedAt),
            codexSnapshotLoader: { context in
                if context.account.id == "0" {
                    try Data("{\"profile\":\"replacement-owner\"}".utf8).write(
                        to: CodexAuthFingerprint.authFileURL(homePath: context.account.homePath),
                        options: .atomic)
                }
                return snapshot
            },
            codexActivityLoader: { _ in nil })
        #expect(result.inputs.map(\.id) == (1..<7).map { "codex:\($0)" })
        #expect(result.failedSourceIDs == ["codex:0"])
        #expect(result.invalidatedSourceIDs == ["codex:0"])
    }

    @Test(CodexCredentialFixtures())
    func `cancelling a seven account batch drains every started child`() async throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent("cancel-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = try (0..<7).map { try Self.makeAccount(id: String($0), root: root) }
        let gate = SpendDashboardPendingLoads<CostUsageTokenSnapshot>()
        defer { gate.close() }
        let request = Self.request(accounts: accounts, now: Self.makeSnapshot().updatedAt)
        let task = Task {
            await SpendDashboardSource.load(
                request,
                codexSnapshotLoader: { _ in try await gate.load() },
                codexActivityLoader: { _ in nil })
        }
        defer { task.cancel() }
        try await gate.waitForPendingCount(3)
        task.cancel()
        gate.close()
        let result = await task.value
        #expect(result.inputs.isEmpty)
        #expect(result.failedSourceIDs == Set(accounts.map { "codex:\($0.id)" }))
        #expect(gate.pendingCount == 0)
    }

    private static func request(accounts: [CodexSpendScanRequest], now: Date) -> SpendDashboardLoadRequest {
        SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [UsageProvider.codex.rawValue],
                codexAccountIdentities: accounts.map { "\($0.id)|\($0.cacheIdentity)" }),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: accounts,
            now: now,
            force: true)
    }

    private static func makeAccount(id: String, root: URL) throws -> CodexSpendScanRequest {
        let home = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = Data("{\"profile\":\"\(id)-owner\"}".utf8)
        try auth.write(to: CodexAuthFingerprint.authFileURL(homePath: home.path), options: .atomic)
        return CodexSpendScanRequest(
            id: id,
            displayName: "Codex · \(id)",
            source: .profileHome(path: home.path),
            homePath: home.path,
            authFingerprint: CodexAuthFingerprint.fingerprint(data: auth),
            authFileWasReadable: true,
            cacheIdentity: "\(id)-cache")
    }

    private static func makeSnapshot() -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1,
            daily: [.init(
                date: "2026-07-15",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 10,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Date(timeIntervalSince1970: 1_784_179_200))
    }
}

private actor SpendDashboardBatchTracker {
    let count: Int
    let reverse: Bool
    private var active = 0
    private(set) var peak = 0
    private(set) var completed = 0

    init(count: Int, reverse: Bool) {
        self.count = count
        self.reverse = reverse
    }

    func load(index: Int) async throws {
        self.active += 1
        self.peak = max(self.peak, self.active)
        defer { self.active -= 1 }
        try await Task.sleep(for: .milliseconds(2 * (self.reverse ? self.count - index : index + 1)))
        self.completed += 1
    }
}

private enum SpendDashboardSyntheticError: Error {
    case failed
}
