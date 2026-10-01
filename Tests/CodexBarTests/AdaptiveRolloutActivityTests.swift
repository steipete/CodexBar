import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AdaptiveRolloutActivityTests {
    private static let now = Date(timeIntervalSince1970: 1_790_769_600)
    private static let daemon = "4234 1 Mon Sep 28 09:03:00 2026 " +
        "/synthetic/codex-home/packages/app-server-daemon/releases/fixture/bin/codex " +
        "app-server --listen unix:// --managed-daemon"

    @Test(arguments: ["", Self.daemon], [30.0, 300.0, 6 * 60.0, 31 * 60.0])
    func `rollout freshness selects cadence without a recognized process`(
        process: String,
        age: TimeInterval) async throws
    {
        let fixture = try Fixture(age: age)
        defer { fixture.remove() }
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in process },
            cwdProvider: { _, _ in [:] },
            appServerTrustValidator: { _ in false },
            directoryScanStartedAt: { .distantFuture })
        let result = await fixture.scan(scanner)
        let activity = result.latestRolloutActivityAt
        let decision = UsageStore.adaptiveRefreshDecision(
            now: Self.now,
            lastMenuOpenAt: nil,
            lastCodingActivityAt: activity,
            lowPowerModeEnabled: false,
            thermalState: .nominal)

        #expect(decision.reason == (age < 300 ? .codingActivity : .longIdle))
        #expect(decision.delay == .seconds(age < 300 ? 300 : 1800))
    }

    @Test(arguments: [
        Self.daemon,
        "4234 1 Mon Sep 28 09:03:00 2026 /usr/local/bin/codex exec",
        "4234 1 Mon Sep 28 09:03:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex app-server",
    ])
    func `activity only never reads rollout contents or asserts a process identity`(process: String) async throws {
        let fixture = try Fixture(age: 30)
        defer { fixture.remove() }
        try Data("not session metadata".utf8).write(to: fixture.rollout)
        try fixture.setAge(30)
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in process },
            cwdProvider: { _, _ in [:] },
            appServerTrustValidator: { _ in
                Issue.record("Activity does not need a signature assertion")
                return false
            },
            rolloutMetadataReader: { _ in
                Issue.record("Activity must not read rollout contents")
                return nil
            },
            directoryScanStartedAt: { .distantFuture })
        let result = await fixture.scan(scanner)

        #expect(result.latestRolloutActivityAt == Self.now.addingTimeInterval(-30))
        #expect(result.sessions.allSatisfy { $0.lastActivityAt == nil && $0.transcriptPath == nil })
    }

    @Test
    func `future rollouts keep the first clamp across scans and age out`() async throws {
        let fixture = try Fixture(age: -3600)
        defer { fixture.remove() }
        let scanner = Self.scanner()
        let first = await fixture.scan(scanner)
        let later = Self.now.addingTimeInterval(360)
        let repeated = await fixture.scan(scanner, now: later)

        #expect(first.latestRolloutActivityAt == Self.now)
        #expect(repeated.latestRolloutActivityAt == Self.now)
        let decision = UsageStore.adaptiveRefreshDecision(
            now: later,
            lastMenuOpenAt: nil,
            lastCodingActivityAt: repeated.latestRolloutActivityAt,
            lowPowerModeEnabled: false,
            thermalState: .nominal)
        #expect(decision.reason == .longIdle)
        #expect(decision.delay == .seconds(1800))
    }

    @Test(arguments: ["entries", "depth", "candidates", "time"])
    func `exhausted rollout budgets produce no activity`(limit: String) async throws {
        let fixture = try Fixture(age: 30)
        defer { fixture.remove() }
        var config = SessionScanConfig()
        switch limit {
        case "entries": config.maxDirectoryEntryCount = 0
        case "depth": config.maxDirectoryDepth = 0
        case "candidates": config.maxCodexRolloutCount = 0
        default: config.adaptiveDirectoryScanBudget = 0
        }
        let result = await fixture.scan(Self.scanner(
            config: config, directoryScanStartedAt: limit == "time" ? .distantPast : .distantFuture))
        #expect(result.latestRolloutActivityAt == nil)
        #expect(result.sessions.isEmpty)
    }

    @Test
    func `rollout activity respects the entry cap without a process`() async throws {
        let fixture = try Fixture(age: 30)
        defer { fixture.remove() }
        for index in 0..<12 {
            let url = fixture.rollout.deletingLastPathComponent().appendingPathComponent("rollout-\(index).jsonl")
            try FileManager.default.copyItem(at: fixture.rollout, to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.now.addingTimeInterval(-30)], ofItemAtPath: url.path)
        }
        let visits = Counter()
        let scanner = LocalAgentSessionScanner(
            config: SessionScanConfig(maxProcessCount: 0, maxDirectoryEntryCount: 3),
            processOutputProvider: { _ in "" },
            cwdProvider: { _, _ in [:] },
            directoryScanStartedAt: { .distantFuture },
            didVisitDirectoryEntry: { visits.increment() })
        let result = await fixture.scan(scanner)
        #expect(result.latestRolloutActivityAt == Self.now.addingTimeInterval(-30))
        #expect(visits.count == 3)
    }

    @Test
    func `yesterday rollouts count while other filenames and deeper directories do not`() async throws {
        let fixture = try Fixture(age: 30)
        defer { fixture.remove() }
        let today = fixture.rollout.deletingLastPathComponent()
        let yesterday = try #require(Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: Self.now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let directory = fixture.root.appendingPathComponent("codex-home/sessions/\(formatter.string(from: yesterday))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.rollout, to: directory.appendingPathComponent("rollout-old.jsonl"))
        for name in ["other.jsonl", "rollout-ignore.txt", "nested/rollout-ignore.jsonl"] {
            let url = today.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("unrelated".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Self.now], ofItemAtPath: url.path)
        }
        let result = await fixture.scan(Self.scanner())
        #expect(result.latestRolloutActivityAt == Self.now.addingTimeInterval(-30))
    }

    @Test(arguments: [1, 2])
    func `file only codex activity cannot starve a live claude transcript`(entryLimit: Int) async throws {
        let fixture = try Fixture(age: 6 * 60)
        defer { fixture.remove() }
        let cwd = "/synthetic/claude-project"
        let directory = fixture.root.appendingPathComponent(".claude/projects")
            .appendingPathComponent(ClaudeSessionProjectMapper.escapedCWD(cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("active.jsonl")
        try Data("synthetic transcript".utf8).write(to: transcript)
        let activity = Self.now.addingTimeInterval(-30)
        try FileManager.default.setAttributes([.modificationDate: activity], ofItemAtPath: transcript.path)
        let visits = Counter()
        let scanner = LocalAgentSessionScanner(
            config: SessionScanConfig(maxDirectoryEntryCount: entryLimit),
            processOutputProvider: { _ in "4234 1 Mon Sep 28 09:03:00 2026 /usr/local/bin/claude" },
            cwdProvider: { _, _ in [4234: cwd] },
            directoryScanStartedAt: { .distantFuture },
            didVisitDirectoryEntry: { visits.increment() })
        let result = await fixture.scan(scanner)
        let latestActivity = AgentSessionsStore.latestActivityAt(
            in: result.sessions, rolloutActivityAt: result.latestRolloutActivityAt)
        let decision = UsageStore.adaptiveRefreshDecision(
            now: Self.now,
            lastMenuOpenAt: nil,
            lastCodingActivityAt: latestActivity,
            lowPowerModeEnabled: false,
            thermalState: .nominal)

        #expect(result.sessions.first?.lastActivityAt == activity)
        #expect(decision.reason == .codingActivity)
        #expect(decision.delay == .seconds(300))
        #expect(visits.count == entryLimit)
    }

    @Test
    func `session enrichment and activity share one directory walk`() async throws {
        let fixture = try Fixture(age: 30)
        defer { fixture.remove() }
        let visits = Counter()
        let reads = Counter()
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in "" },
            cwdProvider: { _, _ in [:] },
            rolloutMetadataReader: { url in
                reads.increment()
                return CodexRolloutFirstLineParser.read(from: url)
            },
            directoryScanStartedAt: { .distantFuture },
            didVisitDirectoryEntry: { visits.increment() })
        let result = await scanner.scanWithActivity(
            now: Self.now,
            environment: fixture.environment,
            includeFileOnlySessions: true,
            includeRolloutActivity: true)

        #expect(visits.count == 1)
        #expect(reads.count == 1)
        #expect(result.sessions.count == 1)
        #expect(result.latestRolloutActivityAt == Self.now.addingTimeInterval(-30))
    }

    @Test
    @MainActor
    func `rollout signal publishes without sessions or power assertions and obeys consent`() async {
        let settings = testSettingsStore(suiteName: "AdaptiveRolloutActivityTests-store")
        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        settings.stayAwakeEnabled = true
        let store = AgentSessionsStore(
            settings: settings,
            localScan: { includeSessions, includeActivity in
                #expect(!includeSessions)
                return .init(latestRolloutActivityAt: includeActivity ? Self.now : nil)
            },
            remoteHostDiscovery: {
                Issue.record("Activity must not discover remote hosts")
                return []
            },
            remoteFetch: { _ in
                Issue.record("Activity must not fetch remote sessions")
                return []
            },
            powerAssertion: .init(acquire: {
                Issue.record("File activity must not acquire a power assertion")
                return nil
            }, release: { _ in }),
            powerState: { (false, .nominal) })
        store.start()
        defer { store.stop() }
        await store.refreshLocal()
        #expect(store.latestLocalActivityAt == Self.now)
        #expect(store.localSessions.isEmpty)
        #expect(!store.isKeepingAwake)

        settings.adaptiveActivityScanConsent = .declined
        store.settingsDidChange(remoteConfigurationChanged: false)
        await store.refreshLocal()
        #expect(store.latestLocalActivityAt == nil)
        #expect(store.localSessions.isEmpty)
    }

    @Test(arguments: [false, true], [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical])
    @MainActor
    func `stay awake respects power constraints for rollout activity`(
        lowPowerModeEnabled: Bool, thermalState: ProcessInfo.ThermalState) async
    {
        let settings = testSettingsStore(suiteName: "AdaptiveRolloutActivityTests-power")
        settings.refreshFrequency = .adaptiveAgentAware
        settings.adaptiveActivityScanConsent = .allowed
        settings.stayAwakeEnabled = true
        let calls = Counter()
        let expectedActivity = !lowPowerModeEnabled && thermalState != .serious && thermalState != .critical
        let store = AgentSessionsStore(
            settings: settings,
            localScan: { includeSessions, includeActivity in
                calls.increment()
                #expect(!includeSessions)
                #expect(includeActivity == expectedActivity)
                return .init()
            },
            remoteHostDiscovery: { [] },
            remoteFetch: { _ in [] },
            powerState: { (lowPowerModeEnabled, thermalState) })
        store.start()
        defer { store.stop() }
        await store.refreshLocal()
        #expect(calls.count == 1)
    }

    private static func scanner(
        config: SessionScanConfig = SessionScanConfig(), directoryScanStartedAt: Date = .distantFuture)
        -> LocalAgentSessionScanner
    {
        LocalAgentSessionScanner(
            config: config,
            processOutputProvider: { _ in "" },
            cwdProvider: { _, _ in [:] },
            directoryScanStartedAt: { directoryScanStartedAt })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { self.lock.withLock { self.value += 1 } }
        var count: Int {
            self.lock.withLock { self.value }
        }
    }

    private struct Fixture {
        let root: URL
        let rollout: URL
        var environment: [String: String] {
            ["HOME": self.root.path, "CODEX_HOME": self.root.appendingPathComponent("codex-home").path, "PATH": ""]
        }

        init(age: TimeInterval) throws {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy/MM/dd"
            let directory = self.root.appendingPathComponent("codex-home/sessions/\(formatter.string(from: Self.now))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.rollout = directory.appendingPathComponent("rollout-fixture.jsonl")
            let source = try AgentSessionParserTests.fixtureURL("agent-session-rollout", extension: "jsonl")
            try FileManager.default.copyItem(at: source, to: self.rollout)
            try self.setAge(age)
        }

        func setAge(_ age: TimeInterval) throws {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.now.addingTimeInterval(-age)], ofItemAtPath: self.rollout.path)
        }

        func scan(_ scanner: LocalAgentSessionScanner, now: Date = AdaptiveRolloutActivityTests.now) async
            -> LocalAgentSessionScanner.ScanResult
        {
            await scanner.scanWithActivity(
                now: now, environment: self.environment, includeFileOnlySessions: false, includeRolloutActivity: true)
        }

        private static var now: Date {
            AdaptiveRolloutActivityTests.now
        }

        func remove() { try? FileManager.default.removeItem(at: self.root) }
    }
}
