import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SettingsStoreTokenCostSourceTests {
    @Test
    func `token cost source detection includes live pi process roots`() throws {
        let fileManager = FileManager.default
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let project = env.root.appendingPathComponent("pi-project", isDirectory: true)
        let projectSettings = project
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json")
        let projectSessions = project.appendingPathComponent("sessions", isDirectory: true)
        let explicitSessions = env.root.appendingPathComponent("explicit-sessions", isDirectory: true)
        try [projectSettings.deletingLastPathComponent(), projectSessions, explicitSessions].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }
        try Data(#"{"sessionDir":"sessions"}"#.utf8).write(to: projectSettings, options: .atomic)
        fileManager.createFile(
            atPath: projectSessions.appendingPathComponent("project.jsonl").path,
            contents: Data("{}".utf8))
        fileManager.createFile(
            atPath: explicitSessions.appendingPathComponent("explicit.jsonl").path,
            contents: Data("{}".utf8))

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["HOME": env.root.path],
            fileManager: fileManager,
            homeDirectory: env.root,
            workingDirectory: env.root,
            processContexts: [
                PiSessionProcessContext(command: "pi", workingDirectory: project),
                PiSessionProcessContext(
                    command: "pi --session-dir \(explicitSessions.path)",
                    workingDirectory: nil),
            ]))
    }

    @Test
    func `token cost source detection includes pi and omp roots`() throws {
        let fileManager = FileManager.default

        let piHome = fileManager.temporaryDirectory.appendingPathComponent(
            "pi-token-cost-\(UUID().uuidString)",
            isDirectory: true)
        let piSessions = piHome
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: piSessions, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: piSessions.appendingPathComponent("session.jsonl").path,
            contents: Data("{}".utf8))
        defer { try? fileManager.removeItem(at: piHome) }

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["HOME": piHome.path],
            fileManager: fileManager,
            homeDirectory: piHome))

        let ompHome = fileManager.temporaryDirectory.appendingPathComponent(
            "omp-token-cost-\(UUID().uuidString)",
            isDirectory: true)
        let ompSessions = ompHome
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: ompSessions, withIntermediateDirectories: true)
        fileManager.createFile(
            atPath: ompSessions.appendingPathComponent("session.jsonl").path,
            contents: Data("{}".utf8))
        defer { try? fileManager.removeItem(at: ompHome) }

        #expect(SettingsStore.hasAnyTokenCostUsageSources(
            env: ["HOME": ompHome.path],
            fileManager: fileManager,
            homeDirectory: ompHome))
    }
}
