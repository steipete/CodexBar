import Foundation
import Testing
@testable import CodexBarCore

struct AppGroupSupportTests {
    @Test
    func `app group identifiers use resolved team-prefixed release and debug variants`() {
        #expect(
            AppGroupSupport.currentGroupID(teamID: "Y5PE65HELJ", bundleID: "com.steipete.codexbar")
                == "Y5PE65HELJ.com.steipete.codexbar")
        #expect(
            AppGroupSupport.currentGroupID(teamID: "ABCDE12345", bundleID: "com.steipete.codexbar.debug")
                == "ABCDE12345.com.steipete.codexbar.debug")
        #expect(
            AppGroupSupport.legacyGroupID(for: "com.steipete.codexbar")
                == "group.com.steipete.codexbar")
        #expect(
            AppGroupSupport.legacyGroupID(for: "com.steipete.codexbar.debug")
                == "group.com.steipete.codexbar.debug")
    }

    @Test
    func `resolved team id falls back to plist and then default`() {
        #expect(
            AppGroupSupport.resolvedTeamID(
                infoDictionaryOverride: [AppGroupSupport.teamIDInfoKey: "ABCDE12345"],
                bundleURLOverride: nil) == "ABCDE12345")
        #expect(
            AppGroupSupport.resolvedTeamID(
                infoDictionaryOverride: nil,
                bundleURLOverride: nil) == AppGroupSupport.defaultTeamID)
    }

    @Test
    func `legacy migration copies snapshot once`() throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanUp() }
        fixture.legacyDefaults.set(true, forKey: "debugDisableKeychainAccess")
        fixture.legacyDefaults.set(UsageProvider.cursor.rawValue, forKey: "widgetSelectedProvider")
        try fixture.writeSnapshot("legacy-snapshot", to: fixture.legacySnapshotURL)

        let result = fixture.migrate()

        #expect(result.status == .migrated)
        #expect(result.copiedSnapshot)
        #expect(result.copiedDefaults == 2)
        #expect(fixture.currentDefaults.bool(forKey: "debugDisableKeychainAccess"))
        #expect(fixture.currentDefaults.string(forKey: "widgetSelectedProvider") == UsageProvider.cursor.rawValue)
        #expect(try Data(contentsOf: fixture.currentSnapshotURL) == Data("legacy-snapshot".utf8))
        #expect(
            fixture.standardDefaults.integer(forKey: AppGroupSupport.migrationVersionKey)
                == AppGroupSupport.migrationVersion)
        #expect(fixture.fileManager.operations == [
            .exists(fixture.currentSnapshotURL.path),
            .exists(fixture.legacySnapshotURL.path),
            .createDirectory(fixture.currentSnapshotURL.deletingLastPathComponent()),
            .copy(fixture.legacySnapshotURL, fixture.currentSnapshotURL),
        ])

        try fixture.writeSnapshot("changed-legacy-snapshot", to: fixture.legacySnapshotURL)
        fixture.fileManager.operations.removeAll()
        let secondResult = fixture.migrate()
        #expect(secondResult.status == .alreadyCompleted)
        #expect(!secondResult.copiedSnapshot)
        #expect(secondResult.copiedDefaults == 0)
        #expect(fixture.fileManager.operations.isEmpty)
        #expect(try Data(contentsOf: fixture.currentSnapshotURL) == Data("legacy-snapshot".utf8))
    }

    @Test
    func `legacy migration preserves existing target shared defaults`() throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanUp() }
        fixture.currentDefaults.set(false, forKey: "debugDisableKeychainAccess")
        fixture.currentDefaults.set(UsageProvider.codex.rawValue, forKey: "widgetSelectedProvider")
        fixture.legacyDefaults.set(true, forKey: "debugDisableKeychainAccess")
        fixture.legacyDefaults.set(UsageProvider.cursor.rawValue, forKey: "widgetSelectedProvider")

        let result = fixture.migrate()

        #expect(result.status == .noChangesNeeded)
        #expect(!result.copiedSnapshot)
        #expect(result.copiedDefaults == 0)
        #expect(!fixture.currentDefaults.bool(forKey: "debugDisableKeychainAccess"))
        #expect(fixture.currentDefaults.string(forKey: "widgetSelectedProvider") == UsageProvider.codex.rawValue)
        #expect(!FileManager.default.fileExists(atPath: fixture.currentSnapshotURL.path))
        #expect(fixture.fileManager.operations == [
            .exists(fixture.currentSnapshotURL.path),
            .exists(fixture.legacySnapshotURL.path),
        ])
    }

    @Test
    func `legacy migration preserves existing target snapshot bytes`() throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSnapshot("current-snapshot", to: fixture.currentSnapshotURL)
        try fixture.writeSnapshot("legacy-snapshot", to: fixture.legacySnapshotURL)

        let result = fixture.migrate()

        #expect(result.status == .noChangesNeeded)
        #expect(!result.copiedSnapshot)
        #expect(result.copiedDefaults == 0)
        #expect(try Data(contentsOf: fixture.currentSnapshotURL) == Data("current-snapshot".utf8))
        #expect(fixture.fileManager.operations == [.exists(fixture.currentSnapshotURL.path)])
    }

    @Test
    func `legacy migration completes when synthetic legacy data is absent`() throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanUp() }

        let result = fixture.migrate()

        #expect(result.status == .noChangesNeeded)
        #expect(!result.copiedSnapshot)
        #expect(result.copiedDefaults == 0)
        #expect(fixture.currentDefaults.dictionaryRepresentation().isEmpty)
        #expect(
            fixture.standardDefaults.integer(forKey: AppGroupSupport.migrationVersionKey)
                == AppGroupSupport.migrationVersion)
        #expect(fixture.fileManager.operations == [
            .exists(fixture.currentSnapshotURL.path),
            .exists(fixture.legacySnapshotURL.path),
        ])
    }

    @Test
    func `unavailable synthetic target does not mark migration complete`() throws {
        let fixture = try MigrationFixture()
        defer { fixture.cleanUp() }

        let result = fixture.migrate(currentDefaultsAvailable: false)

        #expect(result.status == .targetUnavailable)
        #expect(!result.copiedSnapshot)
        #expect(result.copiedDefaults == 0)
        #expect(fixture.standardDefaults.object(forKey: AppGroupSupport.migrationVersionKey) == nil)
        #expect(fixture.fileManager.operations == [.containerLookup])
    }
}

private struct MigrationFixture {
    let root: URL
    let standardDefaults = InMemoryUserDefaults()
    let currentDefaults = InMemoryUserDefaults()
    let legacyDefaults = InMemoryUserDefaults()
    let fileManager: MigrationFileManager

    var currentSnapshotURL: URL {
        self.root.appendingPathComponent("current/widget-snapshot.json")
    }

    var legacySnapshotURL: URL {
        self.root.appendingPathComponent("legacy/widget-snapshot.json")
    }

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupSupportTests-\(UUID().uuidString)", isDirectory: true)
        self.fileManager = MigrationFileManager(root: self.root)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func writeSnapshot(_ value: String, to url: URL) throws {
        try self.fileManager.requireContained(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    func migrate(currentDefaultsAvailable: Bool = true) -> AppGroupSupport.MigrationResult {
        // nil is intentional only for the unavailable-target case: container lookup is stubbed to nil.
        AppGroupSupport.migrateLegacyDataIfNeeded(
            bundleID: "com.steipete.codexbar",
            standardDefaults: self.standardDefaults,
            fileManager: self.fileManager,
            homeDirectory: self.root.appendingPathComponent("home", isDirectory: true),
            currentDefaultsOverride: currentDefaultsAvailable ? self.currentDefaults : nil,
            legacyDefaultsOverride: self.legacyDefaults,
            currentSnapshotURLOverride: self.currentSnapshotURL,
            legacySnapshotURLOverride: self.legacySnapshotURL)
    }

    func cleanUp() {
        do {
            try FileManager.default.removeItem(at: self.root)
        } catch {
            Issue.record("Could not remove synthetic migration fixture: \(error)")
        }
    }
}

private final class MigrationFileManager: FileManager, @unchecked Sendable {
    enum Operation: Equatable {
        case containerLookup
        case homeLookup
        case searchPathLookup
        case exists(String)
        case createDirectory(URL)
        case copy(URL, URL)
    }

    let root: URL
    private let backing = FileManager()
    var operations: [Operation] = []

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier _: String) -> URL? {
        self.operations.append(.containerLookup)
        return nil
    }

    override var homeDirectoryForCurrentUser: URL {
        self.operations.append(.homeLookup)
        return self.root.appendingPathComponent("home", isDirectory: true)
    }

    override func urls(for _: SearchPathDirectory, in _: SearchPathDomainMask) -> [URL] {
        self.operations.append(.searchPathLookup)
        return []
    }

    override func fileExists(atPath path: String) -> Bool {
        self.operations.append(.exists(path))
        guard (try? self.requireContained(URL(fileURLWithPath: path))) != nil else { return false }
        return self.backing.fileExists(atPath: path)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil) throws
    {
        self.operations.append(.createDirectory(url))
        try self.requireContained(url)
        try self.backing.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        self.operations.append(.copy(srcURL, dstURL))
        try self.requireContained(srcURL)
        try self.requireContained(dstURL)
        try self.backing.copyItem(at: srcURL, to: dstURL)
    }

    func requireContained(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard path == self.root.path || path.hasPrefix(self.root.path + "/") else {
            Issue.record("Migration attempted an operation outside its synthetic root: \(url)")
            throw CocoaError(.fileReadNoPermission)
        }
    }
}
