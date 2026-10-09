import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct HomebrewUpgradeCommandTests {
    @Test(arguments: ["homebrew/cask", "steipete/tap"])
    func `upgrade uses the owning prefix and fixed noninteractive arguments`(tap: String) async throws {
        let fixture = try Fixture(tap: tap)
        defer { fixture.remove() }
        try fixture.writeBrew("""
        #!/bin/sh
        if [ "$1" = update ]; then
            [ "$#" = 1 ] || exit 8
            /usr/bin/touch "$0.updated"
            exit 0
        fi
        [ -f "$0.updated" ] || exit 9
        printf '%s\\n' "$@" "$NONINTERACTIVE" "$HOMEBREW_NO_SUDO" "$HOMEBREW_NO_UPGRADE_QUIT_CASKS"
        """)
        let result = try await HomebrewUpdaterController.Dependencies.upgrade(
            appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms)
        #expect(result.stdout.split(separator: "\n").map(String.init) == [
            "upgrade", "--cask", "\(tap)/codexbar", "1", "1", "1",
        ])
    }

    @Test
    func `missing owning brew does not fall back to an unrelated installation`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: HomebrewUpdateError.brewNotFound) {
            try await HomebrewUpdaterController.Dependencies.upgrade(
                appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms)
        }
    }

    @Test
    func `ambiguous ownership disables the helper without enabling Sparkle`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let duplicate = fixture.caskrooms[0].appendingPathComponent("codexbar/0.64.0/CodexBar.app")
        try FileManager.default.createDirectory(
            at: duplicate.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: duplicate, withDestinationURL: fixture.app)
        #expect(InstallOrigin.isHomebrewCask(appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms))
        #expect(InstallOrigin.homebrewPrefix(appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms) == nil)
        await #expect(throws: HomebrewUpdateError.brewNotFound) {
            try await HomebrewUpdaterController.Dependencies.upgrade(
                appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms)
        }
    }

    @Test
    func `failed brew exits retain the diagnostic`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeBrew("#!/bin/sh\nprintf 'synthetic brew failure' >&2\nexit 7\n")
        do {
            _ = try await HomebrewUpdaterController.Dependencies.upgrade(
                appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms)
            Issue.record("Expected the failed command to throw")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            #expect(code == 7)
            #expect(stderr == "synthetic brew failure")
        }
    }

    @Test
    func `bundle version reads fresh metadata after replacement`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let contents = fixture.app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        for version in ["0.65.0", "0.66.0"] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
            #expect(HomebrewUpdaterController.Dependencies.bundleShortVersion(at: fixture.app) == version)
        }
    }

    @Test(arguments: ["homebrew/cask", "steipete/tap"])
    func `active receipt selects the matching feed and ignores nested historical receipts`(tap: String) throws {
        let fixture = try Fixture(tap: tap)
        defer { fixture.remove() }
        let backup = fixture.receiptURL.deletingLastPathComponent()
            .appendingPathComponent("99.0.0/newer-backup/INSTALL_RECEIPT.json")
        try FileManager.default.createDirectory(
            at: backup.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try #"{"source":{"tap":"unrelated/tap"}}"#.write(to: backup, atomically: true, encoding: .utf8)
        let prefix = InstallOrigin.homebrewPrefix(appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms)
        let cask = try HomebrewCask.installed(prefix: prefix)
        #expect(cask.rawValue == tap)
        #expect(cask.qualifiedName == "\(tap)/codexbar")
        let expected = tap == "homebrew/cask"
            ? "https://raw.githubusercontent.com/Homebrew/homebrew-cask/master/Casks/c/codexbar.rb"
            : "https://raw.githubusercontent.com/steipete/homebrew-tap/main/Casks/codexbar.rb"
        #expect(cask.sourceURL.absoluteString == expected)
    }

    @Test(arguments: [
        "invalid",
        "{}",
        #"{"source":null}"#,
        #"{"source":{"tap":""}}"#,
        #"{"source":{"tap":"unrelated/tap"}}"#,
    ])
    func `invalid or unsupported receipts cannot start brew`(receipt: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try receipt.write(to: fixture.receiptURL, atomically: true, encoding: .utf8)
        try fixture.writeBrew("#!/bin/sh\nprintf 'must not run' >&2\nexit 99\n")
        #expect(throws: HomebrewUpdateError.invalidCaskResponse) {
            try HomebrewCask.installed(prefix: fixture.owner)
        }
        await #expect(throws: HomebrewUpdateError.invalidCaskResponse) {
            try await HomebrewUpdaterController.Dependencies.upgrade(
                appBundleURL: fixture.app, caskroomURLs: fixture.caskrooms)
        }
    }

    @Test
    func `missing receipt or owner never defaults to another tap`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.receiptURL)
        #expect(throws: HomebrewUpdateError.invalidCaskResponse) {
            try HomebrewCask.installed(prefix: fixture.owner)
        }
        #expect(throws: HomebrewUpdateError.brewNotFound) {
            try HomebrewCask.installed(prefix: nil)
        }
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let owner: URL
        let caskrooms: [URL]

        init(tap: String = "steipete/tap") throws {
            let manager = FileManager.default
            self.root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.app = self.root.appendingPathComponent("Applications/CodexBar.app")
            // Both prefixes have brew; only the second owns this app. Shell syntax stays literal in the path.
            self.owner = self.root.appendingPathComponent("owner '$(false)")
            let unrelated = self.root.appendingPathComponent("unrelated")
            self.caskrooms = [unrelated, self.owner].map { $0.appendingPathComponent("Caskroom") }
            try manager.createDirectory(at: self.app, withIntermediateDirectories: true)
            for prefix in [unrelated, self.owner] {
                try manager.createDirectory(at: prefix.appendingPathComponent("bin"), withIntermediateDirectories: true)
            }
            let otherBrew = unrelated.appendingPathComponent("bin/brew")
            try "#!/bin/sh\nexit 99\n".write(to: otherBrew, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: otherBrew.path)
            let artifact = self.caskrooms[1].appendingPathComponent("codexbar/0.65.0/CodexBar.app")
            try manager.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: artifact, withDestinationURL: self.app)
            let metadata = self.caskrooms[1].appendingPathComponent("codexbar/.metadata")
            try manager.createDirectory(at: metadata, withIntermediateDirectories: true)
            let receipt = try JSONSerialization.data(withJSONObject: ["source": ["tap": tap, "version": "0.65.0"]])
            try receipt.write(to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
        }

        var receiptURL: URL {
            self.caskrooms[1].appendingPathComponent("codexbar/.metadata/INSTALL_RECEIPT.json")
        }

        func writeBrew(_ script: String) throws {
            let brew = self.owner.appendingPathComponent("bin/brew")
            try script.write(to: brew, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew.path)
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
