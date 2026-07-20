import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

private final class DirectoryEntryVisitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        self.lock.withLock { self.value += 1 }
    }

    var count: Int {
        self.lock.withLock { self.value }
    }
}

private actor AdaptiveLocalScanSpy {
    private(set) var callCount = 0

    func scan(includeFileOnlySessions _: Bool) -> [AgentSession] {
        self.callCount += 1
        return []
    }
}

@MainActor
struct AdaptiveRefreshPerformanceTests {
    @Test
    func `agent aware detection stays within the bounded scan budget`() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AdaptiveRefreshPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let config = SessionScanConfig()
        #expect(config.maxDirectoryEntryCount == 512)
        #expect(config.maxDirectoryDepth == 1)
        #expect(config.adaptiveDirectoryScanBudget == 0.15)

        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let sessionDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let fixtureURL = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
        let fixture = try Data(contentsOf: fixtureURL)
        for index in 0..<config.maxDirectoryEntryCount {
            try fixture.write(to: sessionDirectory.appendingPathComponent("rollout-budget-\(index).jsonl"))
        }
        let nested = sessionDirectory.appendingPathComponent("past-depth-cap", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.write(to: nested.appendingPathComponent("rollout-must-not-be-visited.jsonl"))

        let visits = DirectoryEntryVisitCounter()
        let scanner = LocalAgentSessionScanner(
            config: config,
            processOutputProvider: { _ in
                "201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/codex exec"
            },
            cwdProvider: { _, _ in [201: "/Users/test/Projects/alpha"] },
            didVisitDirectoryEntry: { visits.increment() })

        let startedAt = ContinuousClock.now
        let sessions = await scanner.scan(
            now: now,
            environment: [
                "CODEX_HOME": codexHome.path,
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            includeFileOnlySessions: false)
        let elapsed = startedAt.duration(to: .now)

        #expect(!sessions.isEmpty)
        #expect(visits.count <= config.maxDirectoryEntryCount)
        #expect(
            elapsed < .milliseconds(250),
            "Bounded agent scan exceeded 250 ms: \(elapsed), visited \(visits.count) entries")
    }

    @Test
    func `plain adaptive and missing consent perform zero local scans`() async {
        let settings = testSettingsStore(suiteName: "AdaptiveRefreshPerformanceTests-zero-scan")
        settings.agentSessionsEnabled = false
        settings.adaptiveActivityScanConsent = .allowed
        settings.refreshFrequency = .adaptive
        let spy = AdaptiveLocalScanSpy()
        let store = AgentSessionsStore(
            settings: settings,
            localScan: { includeFileOnlySessions in
                await spy.scan(includeFileOnlySessions: includeFileOnlySessions)
            })

        await store.refreshLocal()
        #expect(await spy.callCount == 0)

        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .undecided
        await store.refreshLocal()
        #expect(await spy.callCount == 0)

        settings.adaptiveActivityScanConsent = .declined
        await store.refreshLocal()
        #expect(await spy.callCount == 0)
    }
}
