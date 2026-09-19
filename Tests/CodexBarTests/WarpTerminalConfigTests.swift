import Foundation
import Testing
@testable import CodexBar

@MainActor
struct WarpTerminalConfigTests {
    @Test
    func `restart removes stale configs and waits for recent interrupted launches`() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = try Self.config(home: home, index: 1, modifiedAt: now.addingTimeInterval(-61))
        let staged = try Self.config(home: home, index: 2, modifiedAt: now.addingTimeInterval(-61), temporary: true)
        let recent = try Self.config(home: home, index: 3, modifiedAt: now.addingTimeInterval(-10))
        var cleanups: [() -> Void] = []
        let launcher = Self.launcher(home: home) { delay, action in
            #expect(delay == .seconds(50))
            cleanups.append(action)
        }

        launcher.cleanUpAbandonedConfigs(now: now)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(cleanups.count == 1)
        let newLaunch = try Self.config(home: home, index: 4, modifiedAt: now)
        cleanups.forEach { $0() }
        #expect(!FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: newLaunch.path))
        cleanups.forEach { $0() }
        #expect(FileManager.default.fileExists(atPath: newLaunch.path))
    }

    @Test
    func `cleanup preserves unrelated unmarked symlink and directory entries`() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        let unmarked = try Self.config(home: home, index: 1, modifiedAt: old, content: "user config")
        let directory = home.appendingPathComponent(".warp/tab_configs")
        let unrelated = directory.appendingPathComponent("codexbar_my_config.toml")
        try WarpTerminalConfig.marker.write(to: unrelated, atomically: true, encoding: .utf8)
        let folder = directory.appendingPathComponent("codexbar_00000000000000000000000000000002.toml")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let nested = folder.appendingPathComponent("keep.txt")
        try "keep".write(to: nested, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("codexbar_00000000000000000000000000000003.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unmarked)

        Self.launcher(home: home) { _, _ in Issue.record("No owned files to schedule") }
            .cleanUpAbandonedConfigs()

        for url in [unmarked, unrelated, nested, link] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(try String(contentsOf: unmarked, encoding: .utf8) == "user config")
    }

    @Test
    func `exclusive write does not overwrite or delete an existing temporary file`() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let temporary = try Self.config(home: home, index: 1, modifiedAt: Date(), temporary: true, content: "keep")
        let target = temporary.deletingLastPathComponent().appendingPathComponent("target.toml")

        #expect(throws: (any Error).self) {
            try WarpTerminalConfig.write(Data("replacement".utf8), temporaryURL: temporary, configURL: target)
        }
        #expect(try String(contentsOf: temporary, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func `scheduled cleanup preserves a replacement at the same path`() throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try Self.config(home: home, index: 1, modifiedAt: Date())
        let candidate = try #require(WarpTerminalConfig.candidate(at: original))
        let moved = original.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: original, to: moved)
        try "replacement".write(to: original, atomically: true, encoding: .utf8)

        WarpTerminalConfig.remove(candidate)

        #expect(try String(contentsOf: original, encoding: .utf8) == "replacement")
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    private static func launcher(
        home: URL,
        schedule: @escaping TerminalLauncher.Dependencies.CleanupScheduler) -> TerminalLauncher
    {
        TerminalLauncher(dependencies: .init(
            homeDirectory: home,
            applicationURL: { _ in nil },
            identifier: UUID.init,
            executeAppleScript: { _ in false },
            open: { _, _, _ in },
            scheduleCleanup: schedule))
    }

    private static func config(
        home: URL,
        index: Int,
        modifiedAt: Date,
        temporary: Bool = false,
        content: String = WarpTerminalConfig.marker) throws -> URL
    {
        let directory = home.appendingPathComponent(".warp/tab_configs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "codexbar_%032x.toml", index)
        let url = directory.appendingPathComponent(temporary ? ".\(name).tmp" : name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private static func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WarpConfigTests-\(UUID().uuidString)")
    }
}
