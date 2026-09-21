import Foundation
import Testing
@testable import CodexBarCore

struct PiProfileResolutionTests {
    @Test
    func `pi provider resolves the selected profile direct sessions layout`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let selectedRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
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
                "OMP_PROFILE": "work",
            ],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == selectedRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(!roots.contains { $0.url == unrelatedRoot.standardizedFileURL })
    }

    @Test
    func `pi provider discovers profiles beneath the configured omp directory`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let selectedRoot = env.root
            .appendingPathComponent(".custom-omp", isDirectory: true)
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
                "PI_CONFIG_DIR": ".custom-omp",
            ],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == selectedRoot.standardizedFileURL })
        #expect(!roots.contains { $0.url == unrelatedRoot.standardizedFileURL })
    }

    @Test
    func `pi provider discovery keeps both profile session layouts during migration`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let profileRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
        let directRoot = profileRoot.appendingPathComponent("sessions", isDirectory: true)
        let legacyRoot = profileRoot
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == directRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains { $0.url == legacyRoot.standardizedFileURL && $0.resolutionIsComplete })
    }

    @Test
    func `pi provider keeps default and xdg omp stores during migration`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let defaultRoot = env.root
            .appendingPathComponent(".omp", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let xdgRoot = env.root
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("omp", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdgRoot, withIntermediateDirectories: true)

        let roots = PiFamilySessionScanner.costSessionRoots(
            environment: ["HOME": env.root.path],
            baseDirectory: env.root)

        #expect(roots.contains { $0.url == defaultRoot.standardizedFileURL && $0.resolutionIsComplete })
        #expect(roots.contains { $0.url == xdgRoot.standardizedFileURL && $0.resolutionIsComplete })
    }
}
