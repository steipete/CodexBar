import Foundation
import Testing
@testable import CodexBarCore

struct PiSessionProcessContextTests {
    @Test
    func `pi cost cache keeps a live process root after the process exits`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 7)
        let project = env.root.appendingPathComponent("live-project", isDirectory: true)
        let liveRoot = env.root.appendingPathComponent("live-session-root", isDirectory: true)
        let defaultRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try [project, liveRoot, defaultRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let liveEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 3, "output": 2, "totalTokens": 5],
            ],
        ]
        let defaultEntry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-4-6",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 4, "output": 3, "totalTokens": 7],
            ],
        ]
        try env.jsonl([liveEntry]).write(
            to: liveRoot.appendingPathComponent("2026-04-07T10-00-00-000Z_live.jsonl"),
            atomically: true,
            encoding: .utf8)
        try env.jsonl([defaultEntry]).write(
            to: defaultRoot.appendingPathComponent("2026-04-07T10-00-00-000Z_default.jsonl"),
            atomically: true,
            encoding: .utf8)

        let environment = ["HOME": env.root.path]
        let liveContext = PiSessionProcessContext(
            command: "/usr/local/bin/pi --session-dir \(liveRoot.path)",
            workingDirectory: project)
        let first = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            environment: environment,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectories: [project],
                processContexts: [liveContext]))
        #expect(first.sessionTokens == 12)

        let afterExit = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .pi,
            environment: environment,
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: CostUsageScanner.Options(cacheRoot: env.cacheRoot),
            piScannerOptions: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectories: [project]))
        #expect(afterExit.sessionTokens == 12)
        #expect(afterExit.historyCoverageIsEstablished)
        let afterExitResult = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .pi,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectories: [project]),
            checkCancellation: nil)
        #expect(afterExitResult.scopeFingerprint == PiSessionCostScanner.scopeFingerprint(options: .init(
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: environment,
            workingDirectories: [project])))
    }

    @Test
    func `pi cost roots carry live process selectors and preserve the default root`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let piProject = env.root.appendingPathComponent("pi-project", isDirectory: true)
        let ompProject = env.root.appendingPathComponent("omp-project", isDirectory: true)
        let piRoot = env.root.appendingPathComponent("pi-process-sessions", isDirectory: true)
        let ompRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try [piProject, ompProject, piRoot, ompRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [piProject, ompProject],
            processContexts: [
                PiSessionProcessContext(
                    command: "/usr/local/bin/pi --session-dir \(piRoot.path)",
                    workingDirectory: piProject),
                PiSessionProcessContext(
                    command: "/usr/local/bin/omp --profile work",
                    workingDirectory: ompProject),
            ])

        #expect(roots.contains { $0.url == piRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains { $0.url == ompRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains { $0.url == piRoot.standardizedFileURL && $0.preserveAfterProcessExit })
        #expect(roots.contains { $0.url == ompRoot.standardizedFileURL && $0.preserveAfterProcessExit })
        let defaultPiRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        #expect(roots.contains {
            $0.url == defaultPiRoot && $0.missingIsKnownEmpty && !$0.preserveAfterProcessExit
        })
    }

    @Test
    func `pi cost roots do not retain environment-only process roots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project", isDirectory: true)
        let selectedRoot = env.root.appendingPathComponent("environment-selected", isDirectory: true)
        try [project, selectedRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: [
                "HOME": env.root.path,
                "PI_CODING_AGENT_SESSION_DIR": selectedRoot.path,
            ],
            baseDirectories: [project],
            processContexts: [
                PiSessionProcessContext(
                    command: "/usr/local/bin/pi",
                    workingDirectory: project),
            ])

        #expect(roots.contains { $0.url == selectedRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains {
            $0.url == selectedRoot.standardizedFileURL && !$0.preserveAfterProcessExit
        })
    }

    @Test
    func `pi cost roots keep current project settings after process exit`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project-settings", isDirectory: true)
        let configuredRoot = env.root.appendingPathComponent("project-session-root", isDirectory: true)
        let settingsDirectory = project.appendingPathComponent(".pi", isDirectory: true)
        try [project, configuredRoot, settingsDirectory].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data("{\"sessionDir\":\"\(configuredRoot.path)\"}".utf8).write(
            to: settingsDirectory.appendingPathComponent("settings.json"),
            options: .atomic)

        let liveContext = PiSessionProcessContext(
            command: "/usr/local/bin/pi",
            workingDirectory: project)
        let liveRoots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [project],
            processContexts: [liveContext])
        let afterExitRoots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [project])

        #expect(liveRoots.contains {
            $0.url == configuredRoot.standardizedFileURL && $0.preserveAfterProcessExit
        })
        #expect(afterExitRoots.contains {
            $0.url == configuredRoot.standardizedFileURL && !$0.preserveAfterProcessExit
        })
    }

    @Test
    func `pi cost roots drop a retained project setting after the setting is removed`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project-settings-removed", isDirectory: true)
        let configuredRoot = env.root.appendingPathComponent("project-session-removed", isDirectory: true)
        let defaultRoot = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let settingsURL = project
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")
        try [project, configuredRoot, defaultRoot, settingsURL.deletingLastPathComponent()].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data(("{\"sessionDir\":\"" + configuredRoot.path + "\"}").utf8).write(
            to: settingsURL,
            options: .atomic)

        let environment = ["HOME": env.root.path]
        let liveOptions = PiSessionCostScanner.Options(
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: environment,
            workingDirectory: project,
            processContexts: [PiSessionProcessContext(command: "/usr/local/bin/pi", workingDirectory: project)])
        let first = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: Date(timeIntervalSince1970: 1_776_000_000),
            until: Date(timeIntervalSince1970: 1_776_000_000),
            now: Date(timeIntervalSince1970: 1_776_000_000),
            options: liveOptions,
            checkCancellation: nil)
        #expect(first.scopeFingerprint?.contains(configuredRoot.path) == true)

        try FileManager.default.removeItem(at: settingsURL)
        let afterRemoval = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: Date(timeIntervalSince1970: 1_776_000_000),
            until: Date(timeIntervalSince1970: 1_776_000_000),
            now: Date(timeIntervalSince1970: 1_776_000_001),
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: project),
            checkCancellation: nil)

        #expect(afterRemoval.scopeFingerprint?.contains(configuredRoot.path) == false)
        #expect(afterRemoval.scopeFingerprint?.contains(defaultRoot.path) == true)
    }

    @Test
    func `pi cost cache revalidates a retained project setting after process exit`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 14)
        let project = env.root.appendingPathComponent("pi-project-settings-retained", isDirectory: true)
        let ambient = env.root.appendingPathComponent("ambient", isDirectory: true)
        let settingsURL = project
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")
        let sessionRoot = project.appendingPathComponent("sessions", isDirectory: true)
        try [project, ambient, sessionRoot, settingsURL.deletingLastPathComponent()].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data(#"{"sessionDir":"sessions"}"#.utf8).write(to: settingsURL, options: .atomic)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 8, "output": 4, "totalTokens": 12],
            ],
        ]
        try env.jsonl([entry]).write(
            to: sessionRoot.appendingPathComponent("2026-04-14T10-00-00-000Z_retained.jsonl"),
            atomically: true,
            encoding: .utf8)

        let environment = ["HOME": env.root.path]
        let first = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient,
                processContexts: [PiSessionProcessContext(
                    command: "/usr/local/bin/pi",
                    workingDirectory: project)]),
            checkCancellation: nil)
        #expect(first.isComplete)
        #expect(first.report.summary?.totalTokens == 12)
        #expect(first.scopeFingerprint?.contains(sessionRoot.path) == true)

        let afterExit = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient),
            checkCancellation: nil)
        #expect(afterExit.isComplete)
        #expect(afterExit.report.summary?.totalTokens == 12)
        #expect(afterExit.scopeFingerprint?.contains(sessionRoot.path) == true)
    }

    @Test
    func `pi cost cache retains both settings selectors when shared roots diverge`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 14)
        let project = env.root.appendingPathComponent("pi-project-settings-retained", isDirectory: true)
        let ambient = env.root.appendingPathComponent("ambient", isDirectory: true)
        let settingsURL = project
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")
        let sessionRoot = project.appendingPathComponent("sessions", isDirectory: true)
        try [project, ambient, sessionRoot, settingsURL.deletingLastPathComponent()].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data(#"{"sessionDir":"sessions"}"#.utf8).write(to: settingsURL, options: .atomic)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 8, "output": 4, "totalTokens": 12],
            ],
        ]
        try env.jsonl([entry]).write(
            to: sessionRoot.appendingPathComponent("2026-04-14T10-00-00-000Z_retained.jsonl"),
            atomically: true,
            encoding: .utf8)

        let environment = ["HOME": env.root.path]
        let first = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient,
                processContexts: [PiSessionProcessContext(
                    command: "/usr/local/bin/pi",
                    workingDirectory: project)]),
            checkCancellation: nil)
        #expect(first.isComplete)
        #expect(first.report.summary?.totalTokens == 12)
        #expect(first.scopeFingerprint?.contains(sessionRoot.path) == true)

        let secondProject = env.root.appendingPathComponent("second-project", isDirectory: true)
        let secondSettings = secondProject.appendingPathComponent(".pi/settings.json")
        try FileManager.default.createDirectory(
            at: secondSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionDir": sessionRoot.path]).write(to: secondSettings)
        let shared = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient,
                processContexts: [project, secondProject].map {
                    PiSessionProcessContext(command: "pi", workingDirectory: $0)
                }), checkCancellation: nil)
        #expect(shared.isComplete)
        #expect(shared.report.summary?.totalTokens == 12)
        let newRoot = project.appendingPathComponent("new-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionDir": newRoot.path]).write(to: settingsURL)
        let afterExit = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient),
            checkCancellation: nil)
        #expect(afterExit.isComplete)
        #expect(afterExit.report.summary?.totalTokens == 12)
        #expect(afterExit.scopeFingerprint?.contains(sessionRoot.path) == true)
    }

    @Test(arguments: [false, true])
    func `pi cost cache preserves the previous report when retained settings are unavailable`(
        usesDefaultRoot: Bool) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 15)
        let project = env.root.appendingPathComponent("pi-project-settings-unavailable", isDirectory: true)
        let ambient = env.root.appendingPathComponent("ambient-unavailable", isDirectory: true)
        let configuredRoot = env.root.appendingPathComponent(
            usesDefaultRoot ? ".pi/agent/sessions" : "settings-unavailable-sessions", isDirectory: true)
        let settingsURL = project
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")
        try [project, ambient, configuredRoot, settingsURL.deletingLastPathComponent()].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data(("{\"sessionDir\":\"" + configuredRoot.path + "\"}").utf8).write(
            to: settingsURL,
            options: .atomic)
        let entry: [String: Any] = [
            "type": "message",
            "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.4",
                "timestamp": Int(day.timeIntervalSince1970 * 1000),
                "usage": ["input": 5, "output": 4, "totalTokens": 9],
            ],
        ]
        try env.jsonl([entry]).write(
            to: configuredRoot.appendingPathComponent("2026-04-15T10-00-00-000Z_unavailable.jsonl"),
            atomically: true,
            encoding: .utf8)

        let environment = ["HOME": env.root.path]
        let first = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient,
                processContexts: [PiSessionProcessContext(
                    command: "/usr/local/bin/pi",
                    workingDirectory: project)]),
            checkCancellation: nil)
        #expect(first.isComplete)
        #expect(first.report.summary?.totalTokens == 9)

        try Data("{".utf8).write(to: settingsURL, options: .atomic)
        let afterFailure = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                environment: environment,
                workingDirectory: ambient),
            checkCancellation: nil)
        #expect(!afterFailure.isComplete)
        #expect(afterFailure.report.summary?.totalTokens == 9)
        #expect(afterFailure.scopeFingerprint == first.scopeFingerprint)
        #expect(PiSessionCostScanner.scopeFingerprint(options: PiSessionCostScanner.Options(
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: environment,
            workingDirectory: ambient)) == first.scopeFingerprint)
    }

    @Test
    func `omp profile process context survives missing cwd`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let profileRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: profileRoot, withIntermediateDirectories: true)

        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in
                "201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/omp --profile work"
            },
            cwdProvider: { _, _ in [:] })
        let contexts = await scanner.piSessionProcessContexts(environment: ["HOME": env.root.path])
        let context = try #require(contexts.first)
        #expect(context.workingDirectory == nil)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            processContexts: contexts)
        #expect(roots.contains {
            $0.url == profileRoot.standardizedFileURL &&
                $0.resolutionIsComplete &&
                $0.preserveAfterProcessExit
        })
    }

    @Test
    func `pi process context cap preserves a distinct older session root`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let sessionRoot = env.root.appendingPathComponent("older-session-root", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        let scanner = LocalAgentSessionScanner(
            config: SessionScanConfig(maxProcessCount: 2),
            processOutputProvider: { _ in
                """
                204 1 Mon Jul 6 09:06:00 2026 /usr/local/bin/pi --model fictitious-alpha
                203 1 Mon Jul 6 09:05:00 2026 /usr/local/bin/pi --model fictitious-beta
                202 1 Mon Jul 6 09:04:00 2026 /usr/local/bin/pi --model fictitious-gamma
                201 1 Sun Jul 5 09:03:00 2026 /usr/local/bin/pi --session-dir \(sessionRoot.path)
                """
            },
            cwdProvider: { pids, _ in
                Dictionary(uniqueKeysWithValues: pids.map { ($0, env.root.path) })
            })

        let contexts = await scanner.piSessionProcessContexts(environment: ["HOME": env.root.path])

        #expect(contexts.count == 2)
        #expect(contexts.contains { $0.command.contains("--model fictitious-alpha") })
        #expect(contexts.contains { $0.command.contains("--session-dir \(sessionRoot.path)") })
    }

    @Test
    func `global relative settings keep CWD-specific retention provenance`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let firstProject = env.root.appendingPathComponent("relative-first", isDirectory: true)
        let secondProject = env.root.appendingPathComponent("relative-second", isDirectory: true)
        let globalSettings = env.root
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json")
        let firstRoot = firstProject.appendingPathComponent("sessions", isDirectory: true)
        let secondRoot = secondProject.appendingPathComponent("sessions", isDirectory: true)
        try [firstProject, secondProject, firstRoot, secondRoot, globalSettings.deletingLastPathComponent()].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data(#"{"sessionDir":"sessions"}"#.utf8).write(to: globalSettings, options: .atomic)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [firstProject, secondProject])
        let firstResolved = try #require(roots.first { $0.url == firstRoot.standardizedFileURL })
        let secondResolved = try #require(roots.first { $0.url == secondRoot.standardizedFileURL })

        #expect(!firstResolved.retentionKeys.isEmpty)
        #expect(!secondResolved.retentionKeys.isEmpty)
        #expect(firstResolved.retentionKeys != secondResolved.retentionKeys)
    }

    @Test
    func `pi cost roots replace a retained project settings selector`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project-settings-switch", isDirectory: true)
        let firstRoot = env.root.appendingPathComponent("project-session-first", isDirectory: true)
        let secondRoot = env.root.appendingPathComponent("project-session-second", isDirectory: true)
        let settingsDirectory = project.appendingPathComponent(".pi", isDirectory: true)
        try [project, firstRoot, secondRoot, settingsDirectory].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 13)

        func writeUsage(to root: URL, totalTokens: Int, name: String) throws {
            let entry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": totalTokens - 1, "output": 1, "totalTokens": totalTokens],
                ],
            ]
            try env.jsonl([entry]).write(
                to: root.appendingPathComponent("2026-04-13T10-00-00-000Z_" + name + ".jsonl"),
                atomically: true,
                encoding: .utf8)
        }

        try Data(("{\"sessionDir\":\"" + firstRoot.path + "\"}").utf8).write(
            to: settingsDirectory.appendingPathComponent("settings.json"),
            options: .atomic)
        try writeUsage(to: firstRoot, totalTokens: 15, name: "first")
        let first = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                workingDirectory: project,
                processContexts: [PiSessionProcessContext(
                    command: "/usr/local/bin/pi",
                    workingDirectory: project)]),
            checkCancellation: nil)
        #expect(first.report.summary?.totalTokens == 15)

        try Data(("{\"sessionDir\":\"" + secondRoot.path + "\"}").utf8).write(
            to: settingsDirectory.appendingPathComponent("settings.json"),
            options: .atomic)
        try writeUsage(to: secondRoot, totalTokens: 30, name: "second")
        let second = try PiSessionCostScanner.loadDailyReportResultCancellable(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 0,
                workingDirectory: project),
            checkCancellation: nil)

        #expect(second.isComplete)
        #expect(second.report.summary?.totalTokens == 30)
        #expect(second.scopeFingerprint?.contains(firstRoot.path) == false)
        #expect(second.scopeFingerprint?.contains(secondRoot.path) == true)
    }

    @Test
    func `pi cost roots preserve whitespace in live session selectors`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project", isDirectory: true)
        let explicitRoot = env.root.appendingPathComponent("pi sessions", isDirectory: true)
        try [project, explicitRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [project],
            processContexts: [
                PiSessionProcessContext(
                    command: "/usr/local/bin/pi --session-dir \(explicitRoot.path)",
                    arguments: ["/usr/local/bin/pi", "--session-dir", explicitRoot.path],
                    workingDirectory: project),
            ])

        #expect(roots.contains { $0.url == explicitRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(!roots
            .contains { $0.url.path == explicitRoot.deletingLastPathComponent().appendingPathComponent("pi").path })
    }

    @Test
    func `pi cost cache drops superseded configured roots`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        let firstRoot = env.root.appendingPathComponent("configured-first", isDirectory: true)
        let secondRoot = env.root.appendingPathComponent("configured-second", isDirectory: true)
        try [firstRoot, secondRoot].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        func writeAssistant(to root: URL, input: Int, output: Int, name: String) throws {
            let entry: [String: Any] = [
                "type": "message",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-5.4",
                    "timestamp": Int(day.timeIntervalSince1970 * 1000),
                    "usage": ["input": input, "output": output, "totalTokens": input + output],
                ],
            ]
            try env.jsonl([entry]).write(
                to: root.appendingPathComponent("2026-04-08T10-00-00-000Z_" + name + ".jsonl"),
                atomically: true,
                encoding: .utf8)
        }

        try writeAssistant(to: firstRoot, input: 10, output: 5, name: "first")
        try writeAssistant(to: secondRoot, input: 20, output: 10, name: "second")

        func options(environment: [String: String]) -> PiSessionCostScanner.Options {
            PiSessionCostScanner.Options(
                cacheRoot: env.cacheRoot,
                refreshMinIntervalSeconds: 3600,
                environment: environment)
        }
        let firstEnvironment = [
            "HOME": env.root.path,
            "PI_CODING_AGENT_SESSION_DIR": firstRoot.path,
        ]
        let secondEnvironment = [
            "HOME": env.root.path,
            "PI_CODING_AGENT_SESSION_DIR": secondRoot.path,
        ]

        let first = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options(environment: firstEnvironment))
        #expect(first.data.first?.totalTokens == 15)

        let second = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options(environment: secondEnvironment))
        #expect(second.data.first?.totalTokens == 30)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).sessionRootsFingerprint?
            .contains(firstRoot.path) != true)
    }
}
