import Foundation
import Testing
@testable import CodexBarCore

struct PiXDGProfileTests {
    @Test
    func `pi provider honors a selected profile in the default xdg data home`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 6)
        let configuredRoot = Self.defaultXDGProfileRoot(home: env.root)
        try FileManager.default.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 9, "output": 3, "totalTokens": 12],
            ],
        ]
        try env.jsonl([entry]).write(
            to: configuredRoot.appendingPathComponent("2026-04-06T10-00-00-000Z_omp-xdg.jsonl"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            environment: [
                "HOME": env.root.path,
                "OMP_PROFILE": "work",
            ],
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot))

        #expect(snapshot.sessionTokens == 12)
        #expect(snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi cost roots discover profiles in the default xdg data home`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let profileRoot = Self.defaultXDGProfileRoot(home: env.root)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == profileRoot.standardizedFileURL })
    }

    private static func defaultXDGProfileRoot(home: URL) -> URL {
        home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }
}
