import Foundation
import Sparkle
import Testing
@testable import CodexBar

@MainActor
struct UpdaterPreferenceSyncTests {
    @Test(arguments: [false, true])
    func `recreating the updater preserves Sparkle's saved install choice`(install: Bool) throws {
        let fixture = try SparklePreferenceFixture(install: install)
        defer { fixture.cleanup() }

        UpdaterPreferenceSync.applyAutomaticChecks(true, to: fixture)
        #expect(fixture.automaticallyDownloadsUpdates == install)
        #expect(fixture.defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == install)
        fixture.reload()
        UpdaterPreferenceSync.applyAutomaticChecks(true, to: fixture)
        #expect(fixture.automaticallyDownloadsUpdates == install)
        #expect(fixture.defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == install)
    }

    @Test
    func `disabling checks suspends installs without erasing the saved opt in`() throws {
        let fixture = try SparklePreferenceFixture(install: true)
        defer { fixture.cleanup() }

        UpdaterPreferenceSync.applyAutomaticChecks(false, to: fixture)
        #expect(!fixture.automaticallyDownloadsUpdates)
        #expect(fixture.defaults.bool(forKey: "SUAutomaticallyUpdate"))
        UpdaterPreferenceSync.applyAutomaticChecks(true, to: fixture)
        #expect(fixture.automaticallyDownloadsUpdates)

        // The same setter is used by Sparkle's update alert. Its opt-out survives the next launch.
        fixture.automaticallyDownloadsUpdates = false
        fixture.reload()
        UpdaterPreferenceSync.applyAutomaticChecks(true, to: fixture)
        #expect(!fixture.automaticallyDownloadsUpdates)
        #expect(fixture.defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == false)
    }
}

/// A real, unstarted Sparkle updater with a synthetic host and a dedicated preference domain.
@MainActor
final class SparklePreferenceFixture: UpdaterProviding {
    let defaults: UserDefaults
    private let directory: URL
    private let bundle: Bundle
    private let domain: String
    private var sparkle: SPUUpdater
    let isAvailable = true
    let unavailableReason: String? = nil
    let updateStatus = UpdateStatus()

    init(install: Bool, checks: Bool = true) throws {
        let domain = "com.example.codexbar.updater-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(checks, forKey: "SUEnableAutomaticChecks")
        defaults.set(checks, forKey: "autoUpdateEnabled")
        defaults.set(install, forKey: "SUAutomaticallyUpdate")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".app")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": domain,
            "CFBundleVersion": "1",
            "CFBundleName": "Synthetic updater",
            "SUEnableAutomaticChecks": true,
            "SUAutomaticallyUpdate": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        self.domain = domain
        self.defaults = defaults
        self.directory = directory
        self.bundle = bundle
        self.sparkle = Self.makeUpdater(bundle: bundle)
    }

    var automaticallyChecksForUpdates: Bool {
        get { self.sparkle.automaticallyChecksForUpdates }
        set { self.sparkle.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { self.sparkle.automaticallyDownloadsUpdates }
        set { self.sparkle.automaticallyDownloadsUpdates = newValue }
    }

    func reload() {
        self.sparkle = Self.makeUpdater(bundle: self.bundle)
    }

    func cleanup() {
        self.defaults.removePersistentDomain(forName: self.domain)
        try? FileManager.default.removeItem(at: self.directory)
    }

    func checkForUpdates(_: Any?) {}
    func installUpdate() {}

    private static func makeUpdater(bundle: Bundle) -> SPUUpdater {
        SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil),
            delegate: nil)
    }
}
