import Foundation
import Testing
@testable import CodexBarCore

struct PiProcessRootEnvironmentTests {
    @Test
    func `process contexts retain distinct profiles for identical commands and directories`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let scanner = LocalAgentSessionScanner(
            config: SessionScanConfig(maxProcessCount: 2),
            processOutputProvider: { _ in
                """
                201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/omp
                202 1 Tue Jul 7 09:03:00 2026 /usr/local/bin/omp
                """
            },
            cwdProvider: { _, _ in [201: env.root.path, 202: env.root.path] },
            processEnvironmentProvider: { _ in
                [
                    201: ["HOME": env.root.path, "OMP_PROFILE": "work"],
                    202: ["HOME": env.root.path, "OMP_PROFILE": "personal"],
                ]
            })

        let contexts = await scanner.piSessionProcessContexts(environment: [
            "HOME": env.root.path, "OMP_PROFILE": "ambient",
        ])
        #expect(contexts.count == 2)
        #expect(Set(contexts.compactMap { $0.selectorEnvironment?["OMP_PROFILE"] }) == ["work", "personal"])
        #expect(Set(contexts.map(PiFamilySessionScanner.processRootSelectorKey)).count == 2)
    }

    @Test(arguments: [false, true])
    func `synthetic process discovery distinguishes unavailable and known empty environments`(
        environmentWasRead: Bool) async
    {
        let provider: LocalAgentSessionScanner.ProcessEnvironmentProvider? = environmentWasRead
            ? { @Sendable _ in [201: [:]] }
            : nil
        let scanner = LocalAgentSessionScanner(
            processOutputProvider: { _ in "201 1 Mon Jul 6 09:03:00 2026 /usr/local/bin/pi" },
            cwdProvider: { _, _ in [201: "/synthetic/project"] },
            processEnvironmentProvider: provider)
        let contexts = await scanner.piSessionProcessContexts(environment: [
            "HOME": "/scanner/home", "PI_CODING_AGENT_DIR": "/scanner/agent",
        ])
        #expect(contexts.count == 1)
        let expected: [String: String]? = environmentWasRead ? [:] : nil
        #expect(contexts.first?.selectorEnvironment == expected)
    }

    @Test
    func `process environment selectors override project settings without ambient cwd replay`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let project = env.root.appendingPathComponent("project", isDirectory: true)
        let selected = env.root.appendingPathComponent("selected-sessions", isDirectory: true)
        let unwanted = project.appendingPathComponent("settings-sessions", isDirectory: true)
        let settings = project.appendingPathComponent(".pi/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionDir": unwanted.path]).write(to: settings)
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [env.root],
            processContexts: [PiSessionProcessContext(
                command: "pi",
                workingDirectory: project,
                selectorEnvironment: [
                    "HOME": env.root.path,
                    "PI_CODING_AGENT_SESSION_DIR": selected.path,
                ])])

        #expect(roots.contains { $0.url.path == selected.path && $0.resolutionIsComplete })
        #expect(!roots.contains { $0.url.path == unwanted.path })
    }

    @Test
    func `environment selected omp profile suppresses unrelated profile discovery`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let selected = env.root.appendingPathComponent(".omp/profiles/work/sessions", isDirectory: true)
        let unrelated = env.root.appendingPathComponent(".omp/profiles/personal/sessions", isDirectory: true)
        try [selected, unrelated].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [env.root],
            processContexts: [PiSessionProcessContext(
                command: "omp",
                workingDirectory: nil,
                selectorEnvironment: ["HOME": env.root.path, "OMP_PROFILE": "work"])])

        #expect(roots.contains { $0.url.path == selected.path && $0.resolutionIsComplete })
        #expect(!roots.contains { $0.url.path == unrelated.path })
    }

    @Test(arguments: [false, true])
    func `relative selectors require known process environment and cwd`(environmentWasRead: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let project = env.root.appendingPathComponent("project", isDirectory: true)
        let selected = project.appendingPathComponent("sessions", isDirectory: true)
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [env.root],
            processContexts: [PiSessionProcessContext(
                command: "pi --session-dir ./sessions",
                workingDirectory: project,
                selectorEnvironment: environmentWasRead ? [:] : nil)])

        #expect(roots.contains { $0.url.path == selected.path } == environmentWasRead)
        #expect(roots.contains { !$0.resolutionIsComplete } == !environmentWasRead)
    }

    @Test(arguments: [false, true])
    func `only absolute argv selectors resolve without process environment or cwd`(homeRelative: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let selected = env.root.appendingPathComponent("sessions", isDirectory: true)
        let selector = homeRelative ? "~/sessions" : selected.path
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectories: [env.root],
            processContexts: [PiSessionProcessContext(
                command: "pi --session-dir \(selector)",
                workingDirectory: nil)])

        #expect(roots.contains { $0.url.path == selected.path } == !homeRelative)
        #expect(roots.contains { !$0.resolutionIsComplete } == homeRelative)
    }

    @Test
    func `retained tilde settings keep the originating process home`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let guiHome = env.root.appendingPathComponent("gui-home", isDirectory: true)
        let processHome = env.root.appendingPathComponent("process-home", isDirectory: true)
        let project = env.root.appendingPathComponent("project", isDirectory: true)
        let settings = project.appendingPathComponent(".pi/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"sessionDir":"~/sessions"}"#.utf8).write(to: settings)
        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": guiHome.path],
            baseDirectories: [guiHome],
            processContexts: [PiSessionProcessContext(
                command: "pi",
                workingDirectory: project,
                selectorEnvironment: ["HOME": processHome.path])])
        let selected = try #require(roots.first { $0.url.path == processHome.appendingPathComponent("sessions").path })
        let key = try #require(selected.retentionKeys.first { $0.hasPrefix("settings:") })
        guard case let .resolved(url, _) = PiFamilySessionScanner.retainedSettingsRootResolution(
            retentionKey: key)
        else {
            Issue.record("Captured process HOME should resolve retained settings")
            return
        }
        #expect(url.path == processHome.appendingPathComponent("sessions").path)

        let legacyKey = "settings:" + settings.standardizedFileURL.resolvingSymlinksInPath().path
        guard case .unavailable = PiFamilySessionScanner.retainedSettingsRootResolution(
            retentionKey: legacyKey)
        else {
            Issue.record("Legacy tilde selectors without HOME evidence must remain unresolved")
            return
        }
    }
}
