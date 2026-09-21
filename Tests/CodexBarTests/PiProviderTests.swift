import Foundation
import Testing
@testable import CodexBarCore

struct PiProviderTests {
    @Test
    func `pi provider honors the configured session directory`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 5)
        let configuredRoot = env.root.appendingPathComponent("configured-pi-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 7, "output": 5, "totalTokens": 12],
            ],
        ]
        let fileURL = configuredRoot.appendingPathComponent(
            "2026-04-05T10-00-00-000Z_configured.jsonl",
            isDirectory: false)
        try env.jsonl([entry]).write(to: fileURL, atomically: true, encoding: .utf8)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            environment: [
                "HOME": env.root.path,
                "PI_CODING_AGENT_SESSION_DIR": configuredRoot.path,
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
    func `pi provider honors the selected omp profile root`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 6)
        let configuredRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: configuredRoot, withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 8, "output": 4, "totalTokens": 12],
            ],
        ]
        let fileURL = configuredRoot.appendingPathComponent(
            "2026-04-06T10-00-00-000Z_omp.jsonl",
            isDirectory: false)
        try env.jsonl([entry]).write(to: fileURL, atomically: true, encoding: .utf8)

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
    func `pi profile selection does not discover unrelated omp profiles`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let selectedRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let unrelatedRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("personal", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: [
                "HOME": env.root.path,
                "PI_PROFILE": "work",
            ],
            baseDirectory: env.root)
        let selectedURL = selectedRoot.standardizedFileURL
        let unrelatedURL = unrelatedRoot.standardizedFileURL

        #expect(roots.contains { $0.url == selectedURL })
        #expect(!roots.contains { $0.url == unrelatedURL })
    }

    @Test
    func `pi cost roots resolve project settings for every correlated working directory`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let firstProject = env.root.appendingPathComponent("first-project", isDirectory: true)
        let secondProject = env.root.appendingPathComponent("second-project", isDirectory: true)
        let firstRoot = env.root.appendingPathComponent("first-sessions", isDirectory: true)
        let secondRoot = env.root.appendingPathComponent("second-sessions", isDirectory: true)
        for directory in [firstProject, secondProject, firstRoot, secondRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (project, sessionRoot) in [(firstProject, firstRoot), (secondProject, secondRoot)] {
            let settings = project.appendingPathComponent(".pi", isDirectory: true)
                .appendingPathComponent("settings.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let value = "{\"sessionDir\":\"\(sessionRoot.path)\"}"
            try Data(value.utf8).write(to: settings)
        }

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [firstProject, secondProject])

        #expect(roots.contains { $0.url == firstRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains { $0.url == secondRoot.standardizedFileURL && $0.resolutionIsComplete })
    }

    @Test
    func `pi working directories follow live pi processes`() async {
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in
                """
                201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/pi --project alpha
                202 1 Tue Jul 7 09:03:00 2026 /usr/local/bin/pi --project beta
                203 1 Wed Jul 8 09:03:00 2026 /usr/local/bin/claude
                """
            },
            cwdProvider: { pids, _ in
                Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
                    switch pid {
                    case 201: (pid, "/projects/alpha")
                    case 202: (pid, "/projects/beta")
                    default: nil
                    }
                })
            })

        let directories = await scanner.piWorkingDirectories(environment: [:])

        #expect(directories.map(\.path) == ["/projects/alpha", "/projects/beta"])
    }

    @Test
    func `pi process contexts keep an absolute session selector when cwd is unavailable`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let sessionRoot = env.root.appendingPathComponent("absolute-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in
                "201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/pi --session-dir \(sessionRoot.path)"
            },
            cwdProvider: { _, _ in [:] })

        let contexts = await scanner.piSessionProcessContexts(environment: ["HOME": env.root.path])
        let context = try #require(contexts.first)
        #expect(context.workingDirectory == nil)
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            processContexts: contexts)
        #expect(roots.contains {
            $0.url == sessionRoot.standardizedFileURL &&
                $0.resolutionIsComplete &&
                $0.preserveAfterProcessExit
        })
    }

    @Test
    func `xdg data home fallback keeps default omp root known empty`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let xdgDataHome = env.root.appendingPathComponent("xdg", isDirectory: true)
        try FileManager.default.createDirectory(at: xdgDataHome, withIntermediateDirectories: true)
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: [
                "HOME": env.root.path,
                "XDG_DATA_HOME": xdgDataHome.path,
            ],
            baseDirectory: env.root)
        let defaultOMPRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        let ompRoot = try #require(roots.first { $0.url.path == defaultOMPRoot.path })
        #expect(ompRoot.missingIsKnownEmpty)
        #expect(ompRoot.resolutionIsComplete)
    }

    @Test
    func `empty auto discovered omp profiles do not make cost roots incomplete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let emptyProfile = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyProfile, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)
        let emptyProfileSessions = emptyProfile
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL

        #expect(!roots.contains { $0.url == emptyProfileSessions })
        let defaultOMPRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        let ompRoot = try #require(roots.first { $0.url == defaultOMPRoot })
        #expect(ompRoot.missingIsKnownEmpty)
        #expect(ompRoot.resolutionIsComplete)
    }

    @Test
    func `omp profile discovery ignores non-directory entries`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let profilesDirectory = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        try Data("profile metadata".utf8).write(
            to: profilesDirectory.appendingPathComponent("README", isDirectory: false))

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)
        let defaultOMPRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        let ompRoot = try #require(roots.first { $0.url == defaultOMPRoot })
        #expect(ompRoot.resolutionIsComplete)
        #expect(!roots.contains { $0.url.path == "/.codexbar-unresolved-omp" })
    }

    @Test
    func `failed omp profile discovery keeps cost roots incomplete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let profilesDirectory = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profilesDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("temporarily unavailable".utf8).write(to: profilesDirectory)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)
        let unresolvedOMPRoot = try #require(roots.first {
            $0.url.path == "/.codexbar-unresolved-omp"
        })

        #expect(!unresolvedOMPRoot.missingIsKnownEmpty)
        #expect(!unresolvedOMPRoot.resolutionIsComplete)
    }

    @Test
    func `failed pi settings resolution keeps cost roots incomplete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let projectSettings = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")
        let globalSettings = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: projectSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: globalSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: projectSettings)
        try Data(#"{"sessionDir":"custom-pi-sessions"}"#.utf8).write(to: globalSettings)

        let rootsWithMalformedProjectSettings = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)
        let unresolvedPiRoot = try #require(rootsWithMalformedProjectSettings.first {
            $0.url.path == "/.codexbar-unresolved-pi"
        })
        #expect(!unresolvedPiRoot.missingIsKnownEmpty)
        #expect(!unresolvedPiRoot.resolutionIsComplete)
        #expect(!rootsWithMalformedProjectSettings.contains {
            $0.url.path.hasSuffix("custom-pi-sessions")
        })

        try FileManager.default.removeItem(at: projectSettings)
        try Data("not json".utf8).write(to: globalSettings)
        let rootsWithMalformedGlobalSettings = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)
        let unresolvedGlobalPiRoot = try #require(rootsWithMalformedGlobalSettings.first {
            $0.url.path == "/.codexbar-unresolved-pi"
        })
        #expect(!unresolvedGlobalPiRoot.missingIsKnownEmpty)
        #expect(!unresolvedGlobalPiRoot.resolutionIsComplete)
    }

    @Test
    func `pi provider exposes an independent aggregate token snapshot`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let entries: [[String: Any]] = [
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 20, "output": 5, "totalTokens": 25],
                ],
            ],
            [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "model": "claude-sonnet-4-6",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 4, "output": 1, "totalTokens": 5],
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-02T10-00-00-000Z_aggregate.jsonl",
            contents: env.jsonl(entries))

        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: piOptions)

        #expect(snapshot.sessionTokens == 30)
        #expect(snapshot.last30DaysTokens == 30)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.costProvenance == .listPriceEstimate)

        let cached = PiSessionCostScanner.loadCachedDailyReport(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot)
        #expect(cached?.summary?.totalTokens == 30)
    }

    @Test
    func `pi provider keeps recognized assistant rows incomplete without valid timestamps`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 3)
        let entries: [[String: Any]] = [
            [
                "type": "message",
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "usage": ["input": 20, "output": 5, "totalTokens": 25],
                ],
            ],
            [
                "type": "message",
                "timestamp": true,
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "openai/gpt-5.4",
                    "usage": ["input": 4, "output": 1, "totalTokens": 5],
                ],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-03T10-00-00-000Z-invalid-timestamps.jsonl",
            contents: env.jsonl(entries))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect((snapshot.sessionTokens ?? 0) == 0)
        #expect(!snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider accepts numeric assistant timestamps`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 4)
        let entry: [String: Any] = [
            "type": "message",
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 7, "output": 5, "totalTokens": 12],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-04T10-00-00-000Z-numeric-timestamp.jsonl",
            contents: env.jsonl([entry]))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(snapshot.sessionTokens == 12)
        #expect(snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider descriptor is registered for token history`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .pi)

        #expect(descriptor.metadata.displayName == "Pi")
        #expect(descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.tokenCost.supportsTokenSnapshot)
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(descriptor.cli.supportsCostCommand)
    }

    @Test
    func `pi provider does not establish history when a configured root is missing`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let missingRoot = env.root.appendingPathComponent("not-mounted")
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: missingRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(!snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider does not establish history when a configured root cannot be inspected`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let unreadableRoot = env.root.appendingPathComponent("not-a-session-directory")
        try Data("not a directory".utf8).write(to: unreadableRoot)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: unreadableRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(!snapshot.historyCoverageIsEstablished)
    }

    @Test
    func `pi provider keeps the last report while a refresh root is unavailable`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-02T10-00-00-000Z_existing.jsonl",
            contents: env.jsonl([entry]))
        let initialOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let initial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: initialOptions)
        #expect(initial.sessionTokens == 25)
        #expect(initial.historyCoverageIsEstablished)

        let unavailableRoot = env.root.appendingPathComponent("temporarily-unavailable")
        try Data("not a directory".utf8).write(to: unavailableRoot)
        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            now: day.addingTimeInterval(1),
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                piSessionsRoot: unavailableRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0))

        #expect(refreshed.sessionTokens == 25)
        #expect(!refreshed.historyCoverageIsEstablished)
        #expect(refreshed.updatedAt == initial.updatedAt)
    }

    @Test
    func `inclusive pi usage propagates incomplete coverage and cache freshness`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 9)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-09T10-00-00-000Z_inclusive.jsonl",
            contents: env.jsonl([entry]))

        let scannerOptions = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let initial = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: true,
            scannerOptions: scannerOptions,
            piScannerOptions: piOptions)
        #expect(initial.last30DaysTokens == 25)
        #expect(initial.historyCoverageIsEstablished)

        try FileManager.default.removeItem(at: env.piSessionsRoot)
        try Data("temporarily unavailable".utf8).write(to: env.piSessionsRoot)
        let refreshed = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day.addingTimeInterval(1),
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: true,
            scannerOptions: scannerOptions,
            piScannerOptions: piOptions)

        #expect(refreshed.last30DaysTokens == 25)
        #expect(!refreshed.historyCoverageIsEstablished)
        #expect(refreshed.updatedAt == initial.updatedAt)
    }

    @Test
    func `pi scanner does not combine old and new roots after an incomplete refresh`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 10)
        let firstRoot = env.root.appendingPathComponent("first-pi-root", isDirectory: true)
        let secondRoot = env.root.appendingPathComponent("second-pi-root", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)

        let firstEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        try env.jsonl([firstEntry]).write(
            to: firstRoot.appendingPathComponent("2026-04-10T10-00-00-000Z_first.jsonl"),
            atomically: true,
            encoding: .utf8)
        let initial = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: firstRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0),
            checkCancellation: nil)
        #expect(initial.isComplete)
        #expect(initial.report.summary?.totalTokens == 25)
        let firstScope = try #require(initial.scopeFingerprint)

        let secondEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 7, "output": 3, "totalTokens": 10],
            ],
        ]
        try env.jsonl([secondEntry]).write(
            to: secondRoot.appendingPathComponent("2026-04-10T10-00-00-000Z_a-valid.jsonl"),
            atomically: true,
            encoding: .utf8)
        try "{malformed}\n".write(
            to: secondRoot.appendingPathComponent("2026-04-10T10-00-00-000Z_z-malformed.jsonl"),
            atomically: true,
            encoding: .utf8)

        let refreshed = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: PiSessionCostScanner.Options(
                piSessionsRoot: secondRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0),
            checkCancellation: nil)

        #expect(!refreshed.isComplete)
        #expect(refreshed.report.summary?.totalTokens == 25)
        #expect(refreshed.scopeFingerprint == firstScope)
        #expect(refreshed.scopeFingerprint != PiSessionCostScanner
            .scopeFingerprint(options: PiSessionCostScanner.Options(
                piSessionsRoot: secondRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0)))
    }

    @Test
    func `pi provider keeps cached usage when an explicit omp root cannot resolve`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 2)
        let defaultPiRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultPiRoot, withIntermediateDirectories: true)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        try env.jsonl([entry]).write(
            to: defaultPiRoot.appendingPathComponent(
                "2026-04-02T10-00-00-000Z_default.jsonl",
                isDirectory: false),
            atomically: true,
            encoding: .utf8)

        let baseEnvironment = ["HOME": env.root.path]
        let initial = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 3600,
                environment: baseEnvironment,
                workingDirectory: env.root),
            checkCancellation: nil)
        #expect(initial.isComplete)
        #expect(initial.report.data.first?.totalTokens == 25)

        for selection in [
            ["HOME": env.root.path, "OMP_PROFILE": "bad/profile"],
            ["HOME": env.root.path, "PI_CONFIG_DIR": "/outside"],
        ] {
            let refreshed = try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: PiSessionCostScanner.Options(
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 3600,
                    environment: selection,
                    workingDirectory: env.root),
                checkCancellation: nil)
            #expect(!refreshed.isComplete)
            #expect(refreshed.report.data.first?.totalTokens == 25)
        }
    }

    @Test
    func `pi provider marks a session read failure incomplete and keeps cached usage`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 3)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 20, "output": 5, "totalTokens": 25],
            ],
        ]
        let fileURL = try env.writePiSessionFile(
            relativePath: "2026-04-03T10-00-00-000Z_read-failure.jsonl",
            contents: env.jsonl([entry]))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0)
        let initial = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options,
            checkCancellation: nil)
        #expect(initial.isComplete)
        #expect(initial.report.data.first?.totalTokens == 25)

        let removeFile: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let refreshed = try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(removeFile) {
            try PiSessionCostScanner.loadDailyReportResultCancellable(
                provider: .codex,
                since: day,
                until: day.addingTimeInterval(1),
                now: day.addingTimeInterval(1),
                options: PiSessionCostScanner.Options(
                    piSessionsRoot: env.piSessionsRoot,
                    cacheRoot: env.cacheRoot,
                    refreshMinIntervalSeconds: 0,
                    forceRescan: true),
                checkCancellation: nil)
        }
        #expect(!refreshed.isComplete)
        #expect(refreshed.report.data.first?.totalTokens == 25)
    }

    @Test
    func `pi provider marks truncated records incomplete`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 4)
        let padding = String(repeating: "x", count: 16 * 1024 * 1024 + 1024)
        let oversized = "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"padding\":\"\(padding)\"}}\n"
        _ = try env.writePiSessionFile(
            relativePath: "2026-04-04T10-00-00-000Z_truncated.jsonl",
            contents: oversized)
        let result = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                piSessionsRoot: env.piSessionsRoot,
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0),
            checkCancellation: nil)

        #expect(!result.isComplete)
    }
}
