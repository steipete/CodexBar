import Foundation
import Observation
import os
import Testing
@testable import CodexBar

@MainActor
struct HomebrewUpdaterControllerTests {
    private static let caskSource = """
    cask "codexbar" do
      version "0.66.0"
      sha256 "a12bbb5e6a6a8d539aa9bd67df6dcae6433f005c639a1d4b9595d8fc218f5616"

      url "https://github.com/steipete/CodexBar/releases/download/v#{version}/CodexBar-macos-universal-#{version}.zip"
      auto_updates true
    end
    """

    @MainActor
    private final class Fixture {
        var installedVersion = "0.65.0"
        var caskSource = HomebrewUpdaterControllerTests.caskSource
        var fetchError: Error?
        var fetchCount = 0
        var upgradeError: Error?
        var versionAfterUpgrade: String?
        var upgradeCount = 0
        var upgradeWait: CheckedContinuation<Void, Never>?
        var suspendUpgrade = false
        var relaunchCount = 0
        var notificationVersions: [String] = []
        var submittedVersion: String?
        var removedVersions: [String] = []
        var notificationIsCurrent: (@MainActor () -> Bool)?
        var notificationCompletion: (@MainActor (Bool) -> Void)?

        func makeController(
            savedAutoCheck: Bool = false,
            cask: HomebrewCask = .tap) -> HomebrewUpdaterController
        {
            HomebrewUpdaterController(
                savedAutoCheck: savedAutoCheck,
                dependencies: HomebrewUpdaterController.Dependencies(
                    installedVersion: { self.installedVersion },
                    fetchCaskSource: { @MainActor in
                        self.fetchCount += 1
                        if let error = self.fetchError { throw error }
                        return self.caskSource
                    },
                    runUpgrade: { @MainActor in
                        self.upgradeCount += 1
                        if self.suspendUpgrade, self.upgradeCount == 1 {
                            await withCheckedContinuation { self.upgradeWait = $0 }
                        }
                        if let error = self.upgradeError { throw error }
                        if let version = self.versionAfterUpgrade { self.installedVersion = version }
                    },
                    relaunch: { self.relaunchCount += 1 },
                    cask: { cask }),
                notifier: HomebrewUpdateNotifier(dependencies: .init(
                    lastSubmittedVersion: { self.submittedVersion },
                    saveSubmittedVersion: { self.submittedVersion = $0 },
                    post: { version, isCurrent, completion in
                        self.notificationVersions.append(version)
                        self.notificationIsCurrent = isCurrent
                        self.notificationCompletion = completion
                    },
                    remove: { self.removedVersions.append($0) })),
                startScheduledChecks: false)
        }
    }

    @Test
    func `automatic checks announce newer releases while manual checks stay in the page`() async {
        let fixture = Fixture()
        let controller = fixture.makeController(savedAutoCheck: true)
        await controller.performCheck()
        #expect(fixture.notificationVersions.isEmpty)
        await controller.performCheck(source: .automatic)
        #expect(fixture.notificationVersions == ["0.66.0"])
    }

    @Test
    func `disabled automatic checks and up to date versions do not notify`() async {
        let fixture = Fixture()
        let disabled = fixture.makeController()
        await disabled.performCheck(source: .automatic)
        #expect(fixture.fetchCount == 0)
        #expect(fixture.notificationVersions.isEmpty)
        await disabled.performCheck()
        #expect(fixture.fetchCount == 1)
        #expect(fixture.upgradeCount == 0)
        #expect(fixture.notificationVersions.isEmpty)
        fixture.installedVersion = "0.66.0"
        let current = fixture.makeController(savedAutoCheck: true)
        await current.performCheck(source: .automatic)
        #expect(fixture.notificationVersions.isEmpty)
    }

    @Test
    func `starting with automatic checks disabled retires a notice from the previous launch`() {
        let fixture = Fixture()
        fixture.submittedVersion = "0.66.0"
        let controller = fixture.makeController(savedAutoCheck: false)
        #expect(!controller.automaticallyChecksForUpdates)
        #expect(fixture.removedVersions == ["0.66.0"])
        #expect(fixture.submittedVersion == "0.66.0")
        #expect(fixture.fetchCount == 0)
        #expect(fixture.upgradeCount == 0)
    }

    @Test
    func `failed background checks do not announce a previously found version`() async {
        let fixture = Fixture()
        let controller = fixture.makeController(savedAutoCheck: true)
        await controller.performCheck()
        fixture.fetchError = HomebrewUpdateError.invalidCaskResponse
        await controller.performCheck(source: .automatic)
        #expect(fixture.notificationVersions.isEmpty)
        #expect(controller.updateStatus.availableVersion == "0.66.0")
    }

    @Test
    func `disabling checks invalidates an update notice awaiting submission`() async {
        let fixture = Fixture()
        let controller = fixture.makeController(savedAutoCheck: true)
        await controller.performCheck(source: .automatic)
        #expect(fixture.notificationIsCurrent?() == true)
        controller.automaticallyChecksForUpdates = false
        #expect(fixture.notificationIsCurrent?() == false)
        fixture.notificationCompletion?(false)
    }

    @Test
    func `starting an upgrade invalidates an update notice even when the upgrade fails`() async {
        let fixture = Fixture()
        let controller = fixture.makeController(savedAutoCheck: true)
        await controller.performCheck(source: .automatic)
        #expect(fixture.notificationIsCurrent?() == true)
        fixture.upgradeError = HomebrewUpdateError.brewNotFound
        await controller.performInstall()
        #expect(fixture.notificationIsCurrent?() == false)
        #expect(controller.updateStatus.availableVersion == "0.66.0")
        fixture.notificationCompletion?(false)
    }

    @Test
    func `parses the version declared by the cask`() {
        #expect(HomebrewCaskVersion.parse(caskSource: Self.caskSource) == "0.66.0")
        #expect(HomebrewCaskVersion.parse(caskSource: "cask \"codexbar\" do\nend") == nil)
        #expect(HomebrewCaskVersion.parse(caskSource: "  version \"\"") == nil)
    }

    @Test
    func `version parsing preserves whitespace and ignores unrelated declarations`() {
        #expect(HomebrewCaskVersion.parse(caskSource: "# version \"99.0.0\"\n  version \" 0.66.0 \"\r\n") == "0.66.0")
        #expect(HomebrewCaskVersion.parse(caskSource: "\tversion  \"0.66.0-beta.1\"") == "0.66.0-beta.1")
        #expect(HomebrewCaskVersion.parse(caskSource: "version \t\"0.66.0\"") == "0.66.0")
        #expect(HomebrewCaskVersion.parse(caskSource: "version :latest") == nil)
        #expect(HomebrewCaskVersion.parse(caskSource: "version \"   \"") == nil)
        #expect(HomebrewCaskVersion.parse(caskSource: "version \"unterminated") == nil)
    }

    @Test(arguments: [HomebrewCask.official, .tap])
    func `recovery command follows the selected cask`(cask: HomebrewCask) {
        let controller = Fixture().makeController(cask: cask)
        let expected = cask == .official
            ? "brew upgrade --cask homebrew/cask/codexbar"
            : "brew upgrade --cask steipete/tap/codexbar"
        #expect(controller.manualUpdateCommand == expected)
    }

    @Test
    func `unknown cask ownership fails without inventing a recovery target`() async {
        let controller = HomebrewUpdaterController(
            savedAutoCheck: false,
            dependencies: .init(
                installedVersion: { "0.65.0" },
                fetchCaskSource: { throw HomebrewUpdateError.invalidCaskResponse },
                runUpgrade: {},
                relaunch: {},
                cask: { throw HomebrewUpdateError.invalidCaskResponse }),
            startScheduledChecks: false)
        await controller.performCheck()
        #expect(controller.manualUpdateCommand == nil)
        #expect(controller.updateStatus.availableVersion == nil)
        #expect(controller.phase == .failed(HomebrewUpdateError.invalidCaskResponse.localizedDescription))
    }

    @Test
    func `compares versions numerically`() {
        #expect(HomebrewCaskVersion.isNewer("0.66.0", than: "0.65.0"))
        #expect(HomebrewCaskVersion.isNewer("0.100.0", than: "0.99.1"))
        #expect(!HomebrewCaskVersion.isNewer("0.65.0", than: "0.65.0"))
        #expect(!HomebrewCaskVersion.isNewer("0.64.9", than: "0.65.0"))
    }

    @Test
    func `stable release supersedes its prerelease`() {
        #expect(HomebrewCaskVersion.isNewer("0.66.0", than: "0.66.0-beta.1"))
        #expect(!HomebrewCaskVersion.isNewer("0.66.0-beta.1", than: "0.66.0"))
    }

    @Test
    func `stale local tap cannot report an incomplete upgrade as success`() async {
        let fixture = Fixture()
        fixture.caskSource = "version \"0.67.0\""
        fixture.versionAfterUpgrade = "0.66.0"
        let controller = fixture.makeController()
        await controller.performCheck()
        await controller.performInstall()
        #expect(fixture.relaunchCount == 0)
        #expect(controller.phase == .failed(HomebrewUpdateError.versionUnchanged("0.66.0").localizedDescription))
    }

    @Test
    func `newer cask version is offered for install`() async {
        let fixture = Fixture()
        let controller = fixture.makeController()

        await controller.performCheck()

        #expect(controller.phase == .available("0.66.0"))
        #expect(controller.updateStatus.availableVersion == "0.66.0")
    }

    @Test
    func `older remote tap is not offered as a downgrade`() async {
        let fixture = Fixture()
        fixture.installedVersion = "0.67.0"
        let controller = fixture.makeController()
        await controller.performCheck()
        await controller.performInstall()
        #expect(controller.phase == .upToDate)
        #expect(controller.updateStatus.availableVersion == nil)
        #expect(fixture.upgradeCount == 0)
    }

    @Test
    func `matching cask version reports up to date`() async {
        let fixture = Fixture()
        fixture.installedVersion = "0.66.0"
        let controller = fixture.makeController()

        await controller.performCheck()

        #expect(controller.phase == .upToDate)
        #expect(controller.updateStatus.availableVersion == nil)
    }

    @Test
    func `failed check keeps the update and exposes recovery`() async {
        let fixture = Fixture()
        let controller = fixture.makeController()
        await controller.performCheck()

        fixture.fetchError = HomebrewUpdateError.invalidCaskResponse
        await controller.performCheck()

        #expect(controller.phase == .failed(HomebrewUpdateError.invalidCaskResponse.localizedDescription))
        #expect(controller.updateStatus.availableVersion == "0.66.0")
    }

    @Test
    func `successful upgrade relaunches the app`() async {
        let fixture = Fixture()
        fixture.versionAfterUpgrade = "0.66.0"
        let controller = fixture.makeController()
        await controller.performCheck()

        await controller.performInstall()

        #expect(fixture.upgradeCount == 1)
        #expect(fixture.relaunchCount == 1)
        #expect(controller.updateStatus.availableVersion == nil)
        #expect(controller.updateStatus.isInstalling == false)
    }

    @Test
    func `upgrade that leaves the version unchanged fails without relaunching`() async {
        let fixture = Fixture()
        let controller = fixture.makeController()
        await controller.performCheck()

        await controller.performInstall()

        #expect(fixture.relaunchCount == 0)
        #expect(controller.phase == .failed(HomebrewUpdateError.versionUnchanged("0.65.0").localizedDescription))
        #expect(controller.updateStatus.availableVersion == "0.66.0")
        #expect(controller.updateStatus.isInstalling == false)
    }

    @Test
    func `missing brew surfaces a failure`() async {
        let fixture = Fixture()
        fixture.upgradeError = HomebrewUpdateError.brewNotFound
        let controller = fixture.makeController()
        await controller.performCheck()

        await controller.performInstall()

        #expect(fixture.relaunchCount == 0)
        #expect(controller.phase == .failed(HomebrewUpdateError.brewNotFound.localizedDescription))
    }

    @Test
    func `concurrent install and check cannot overlap an upgrade`() async {
        let fixture = Fixture()
        fixture.suspendUpgrade = true
        fixture.versionAfterUpgrade = "0.66.0"
        let controller = fixture.makeController()
        await controller.performCheck()
        let first = Task { await controller.performInstall() }
        while fixture.upgradeWait == nil {
            await Task.yield()
        }

        await controller.performCheck()
        #expect(controller.phase == .installing)
        await controller.performInstall()
        #expect(fixture.upgradeCount == 1)
        #expect(controller.updateStatus.isInstalling)
        fixture.upgradeWait?.resume()
        await first.value
        #expect(fixture.relaunchCount == 1)
    }

    @Test
    func `failed initial check exposes the error for manual recovery`() async {
        let fixture = Fixture()
        fixture.fetchError = HomebrewUpdateError.invalidCaskResponse
        let controller = fixture.makeController()
        await controller.performCheck()
        #expect(controller.phase == .failed(HomebrewUpdateError.invalidCaskResponse.localizedDescription))
    }

    @Test
    func `brew environment puts the brew prefix first on PATH`() {
        let environment = HomebrewUpdaterController.Dependencies.brewEnvironment(
            brewPath: "/opt/homebrew/bin/brew",
            base: ["HOME": "/Users/example", "PATH": "/custom"])

        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(environment["HOMEBREW_NO_SUDO"] == "1")
        #expect(environment["NONINTERACTIVE"] == "1")
    }

    @Test
    func `update status changes notify menu observers`() {
        let status = UpdateStatus()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = status.availableVersion
            _ = status.isInstalling
        } onChange: {
            changed.withLock { $0 = true }
        }
        status.availableVersion = "0.66.0"
        #expect(changed.withLock { $0 })
        changed.withLock { $0 = false }
        withObservationTracking {
            _ = status.isInstalling
        } onChange: {
            changed.withLock { $0 = true }
        }
        status.isInstalling = true
        #expect(changed.withLock { $0 })
    }

    @Test
    func `menu offers available update and shows install progress`() {
        let available = MenuDescriptor.metaSection(updateReady: false, availableUpdateVersion: "0.66.0")
        #expect(available.entries.contains { entry in
            if case let .action(title, .installUpdate) = entry { return title == "Update to 0.66.0" }
            return false
        })

        let installing = MenuDescriptor.metaSection(
            updateReady: false,
            availableUpdateVersion: "0.66.0",
            isInstallingUpdate: true)
        #expect(installing.entries.contains { entry in
            if case let .text(title, _) = entry { return title == "Updating with Homebrew…" }
            return false
        })
        #expect(!installing.entries.contains { entry in
            if case .action(_, .installUpdate) = entry { return true }
            return false
        })
    }
}
