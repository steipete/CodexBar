import Foundation
import Testing
@testable import CodexBarCore
#if os(macOS)
import Security
#endif

struct KeychainCacheApplicationPathTests {
    enum LinkStyle: CaseIterable, Sendable {
        case direct, relative, chained, parentDirectory
    }

    @Test
    func `cache trust fails closed without a running image or for an external alias`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = try fixture.makeAlias(style: .relative)
        #expect(KeychainCacheStore.trustedApplicationPathsForCacheAccess(executableURL: nil).isEmpty)
        #expect(KeychainCacheStore.invokingApplicationPathsForCacheAccess(executableURL: nil).isEmpty)
        #expect(KeychainCacheStore.trustedApplicationPathsForCacheAccess(executableURL: alias).isEmpty)
        let missing = fixture.root.appendingPathComponent("missing")
        #expect(KeychainCacheStore.invokingApplicationPathsForCacheAccess(executableURL: missing).isEmpty)
    }

    #if os(macOS)
    @Test(arguments: LinkStyle.allCases)
    func `kernel identifies the bundled executable through each supported launch alias`(style: LinkStyle) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = try fixture.makeAlias(style: style)
        let process = try fixture.start(through: alias)
        defer { fixture.stop(process) }
        let path = try #require(DarwinProcessEnumerator.executablePath(pid: process.processIdentifier))
        #expect(URL(fileURLWithPath: path).standardizedFileURL.path == fixture.helper.path)
        let runningImage = URL(fileURLWithPath: path)
        #expect(KeychainCacheStore.appBundleURL(containing: runningImage)?.path == fixture.app.path)
        #expect(KeychainCacheStore.invokingApplicationPathsForCacheAccess(executableURL: runningImage) == [path])
        let trustedPaths = KeychainCacheStore.trustedApplicationPathsForCacheAccess(executableURL: runningImage)
        #expect(self.normalizedPaths(trustedPaths) == [fixture.app.path, fixture.helper.path])
    }

    @Test(arguments: [false, true])
    func `retargeting a launch alias cannot add another app to cache trust`(beforeDiscovery: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = try fixture.makeAlias(style: .relative)
        let process = try fixture.start(through: alias)
        defer { fixture.stop(process) }
        let other = fixture.root.appendingPathComponent("Other.app/Contents/Helpers/CodexBarCLI")
        try FileManager.default.createDirectory(
            at: other.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: other.path)
        func retarget() throws {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: other)
        }
        if beforeDiscovery { try retarget() }
        let path = try #require(DarwinProcessEnumerator.executablePath(pid: process.processIdentifier))
        #expect(URL(fileURLWithPath: path).standardizedFileURL.path == fixture.helper.path)
        let runningImage = URL(fileURLWithPath: path)
        var retargeted = beforeDiscovery
        var retargetError: Error?
        let paths = KeychainCacheStore.trustedApplicationPathsForCacheAccess(
            executableURL: runningImage,
            fileExists: { candidate in
                if !retargeted {
                    retargeted = true
                    do { try retarget() } catch { retargetError = error }
                }
                return FileManager.default.fileExists(atPath: candidate)
            })
        if let retargetError { throw retargetError }
        #expect(retargeted)
        #expect(alias.resolvingSymlinksInPath().path == other.path)
        #expect(self.normalizedPaths(paths) == [fixture.app.path, fixture.helper.path])
        #expect(!paths.contains(alias.path))
        #expect(!paths.contains(other.path))

        // Trust objects capture identities now, after the adversarial retarget. No Keychain item is accessed.
        let (creationStatus, reference) = KeychainCacheStore.createTrustedApplication(path: fixture.helper.path)
        #expect(creationStatus == errSecSuccess)
        let trusted = try #require(reference)
        #expect(KeychainAccessPreflight.trustedApplication(trusted, validatesExecutableAt: path) == errSecSuccess)
        for replacement in [alias.path, other.path] {
            let validation = KeychainAccessPreflight.trustedApplication(trusted, validatesExecutableAt: replacement)
            #expect(validation == OSStatus(CSSMERR_CSP_VERIFY_FAILED))
            #expect(KeychainAccessPreflight.evaluateDecryptACL(
                trustedApplicationValidationStatuses: [validation],
                promptSelector: []) == .rejected)
        }
    }
    #endif

    private func normalizedPaths(_ paths: [String]) -> Set<String> {
        // The kernel retains /private/var while Foundation standardization uses /var.
        Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    private struct Fixture {
        let root: URL
        let app: URL
        let helper: URL
        let bin: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexbar-cache-paths-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            self.app = self.root.appendingPathComponent("CodexBar.app", isDirectory: true)
            self.helper = self.app.appendingPathComponent("Contents/Helpers/CodexBarCLI")
            self.bin = self.root.appendingPathComponent("bin", isDirectory: true)
            for directory in [self.helper.deletingLastPathComponent(), self.bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            #if os(macOS)
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: self.helper.path)
            #else
            try Data().write(to: self.helper)
            #endif
        }

        func makeAlias(style: LinkStyle) throws -> URL {
            let manager = FileManager.default
            let alias = self.bin.appendingPathComponent("codexbar")
            switch style {
            case .direct:
                try manager.createSymbolicLink(at: alias, withDestinationURL: self.helper)
            case .relative:
                try manager.createSymbolicLink(
                    atPath: alias.path,
                    withDestinationPath: "../CodexBar.app/Contents/Helpers/CodexBarCLI")
            case .chained:
                let intermediate = self.bin.appendingPathComponent("intermediate")
                try manager.createSymbolicLink(at: intermediate, withDestinationURL: self.helper)
                try manager.createSymbolicLink(atPath: alias.path, withDestinationPath: "intermediate")
            case .parentDirectory:
                let parent = self.root.appendingPathComponent("linked-helpers", isDirectory: true)
                try manager.createSymbolicLink(at: parent, withDestinationURL: self.helper.deletingLastPathComponent())
                return parent.appendingPathComponent("CodexBarCLI")
            }
            return alias
        }

        #if os(macOS)
        func start(through alias: URL) throws -> Process {
            let process = Process()
            process.executableURL = alias
            process.arguments = ["60"]
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }

        func stop(_ process: Process) {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        #endif

        func remove() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
