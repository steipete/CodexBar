import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import Security

struct KeychainAccessPreflightSelfValidationTests {
    @Test
    func `native self validation accepts its requirement and rejects another executable`() throws {
        // These are code-signing handles only; no Keychain items are opened or created.
        let path = try #require(KeychainCacheStore.runningExecutableURLForCacheAccess?.path)
        for trustedPath in [path, "/usr/bin/true"] {
            let (creationStatus, reference) = KeychainCacheStore.createTrustedApplication(path: trustedPath)
            #expect(creationStatus == errSecSuccess)
            let application = try #require(reference)
            #expect(KeychainAccessPreflight.trustedApplication(application, validatesExecutableAt: path) ==
                (trustedPath == path ? errSecSuccess : OSStatus(CSSMERR_CSP_VERIFY_FAILED)))
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var bundle: URL {
            self.root.appendingPathComponent("Fixture.app")
        }

        var main: URL {
            self.bundle.appendingPathComponent("Contents/MacOS/Fixture")
        }

        var helper: URL {
            self.bundle.appendingPathComponent("Contents/Helpers/FixtureCLI")
        }

        var alias: URL {
            self.root.appendingPathComponent("alias")
        }

        init() throws {
            for executable in [self.main, self.helper] {
                try FileManager.default.createDirectory(
                    at: executable.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try Data("synthetic executable".utf8).write(to: executable)
            }
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleExecutable": "Fixture", "CFBundleVersion": "1",
                    "CFBundleIdentifier": "test.codexbar.fixture.\(UUID().uuidString)",
                    "CFBundlePackageType": "APPL",
                ],
                format: .xml,
                options: 0)
            try data.write(to: self.bundle.appendingPathComponent("Contents/Info.plist"))
            try FileManager.default.createSymbolicLink(at: self.alias, withDestinationURL: self.main)
        }

        func remove() { try? FileManager.default.removeItem(at: self.root) }
    }

    @Test
    func `own executable bundle and resolved alias avoid every static resource validation`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var dynamicChecks = 0
        var staticChecks = 0
        let paths = [
            fixture.main.path, fixture.bundle.path, fixture.alias.path,
            fixture.bundle.appendingPathComponent("Contents/../Contents/MacOS/Fixture").path,
        ]
        for _ in 0..<25 {
            for path in paths {
                #expect(KeychainAccessPreflight.validateApplication(
                    at: path,
                    executableURL: fixture.main,
                    selfCheck: { dynamicChecks += 1; return errSecSuccess },
                    staticCheck: { staticChecks += 1; return errSecSuccess }) == errSecSuccess)
            }
        }
        #expect(dynamicChecks == 100)
        #expect(staticChecks == 0)
    }

    @Test
    func `helper can validate itself but cannot authorize the enclosing app or sibling`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in [fixture.helper.path, fixture.main.path, fixture.bundle.path] {
            var dynamicChecks = 0
            var staticChecks = 0
            let ownPath = path == fixture.helper.path
            #expect(KeychainAccessPreflight.validateApplication(
                at: path,
                executableURL: fixture.helper,
                selfCheck: { dynamicChecks += 1; return errSecSuccess },
                staticCheck: { staticChecks += 1; return errSecParam }) == (ownPath ? errSecSuccess : errSecParam))
            #expect(dynamicChecks == (ownPath ? 1 : 0))
            #expect(staticChecks == (ownPath ? 0 : 1))
        }
    }

    @Test
    func `foreign missing and retargeted paths retain static validation`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.alias)
        try FileManager.default.createSymbolicLink(at: fixture.alias, withDestinationURL: fixture.helper)
        for executable in [fixture.main, nil] {
            for path in [fixture.helper.path, fixture.alias.path, fixture.root.appendingPathComponent("missing").path] {
                var staticChecks = 0
                let result = KeychainAccessPreflight.validateApplication(
                    at: path,
                    executableURL: executable,
                    selfCheck: { Issue.record("Foreign paths must not validate self"); return errSecSuccess },
                    staticCheck: { staticChecks += 1; return errSecNotAvailable })
                #expect(result == errSecNotAvailable)
                #expect(staticChecks == 1)
            }
        }
    }

    @Test(arguments: [OSStatus(errSecSuccess), OSStatus(CSSMERR_CSP_VERIFY_FAILED), errSecParam, nil])
    func `unavailable self check falls back with the original static status`(_ fallback: OSStatus?) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var staticChecks = 0
        // nil covers missing SPI, failed requirement copy, and legacy ACLs without a requirement.
        let result = KeychainAccessPreflight.validateApplication(
            at: fixture.main.path,
            executableURL: fixture.main,
            selfCheck: { nil },
            staticCheck: { staticChecks += 1; return fallback })
        #expect(result == fallback)
        #expect(staticChecks == 1)
    }

    @Test(arguments: [
        errSecSuccess, errSecCSReqFailed, errSecNotAvailable, errSecParam, errSecInternalComponent,
    ])
    func `dynamic statuses preserve decrypt ACL decisions without retrying statically`(_ dynamic: OSStatus) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = KeychainAccessPreflight.validateApplication(
            at: fixture.main.path,
            executableURL: fixture.main,
            selfCheck: { dynamic },
            staticCheck: { Issue.record("A completed self check must not validate statically"); return nil })
        let expected: KeychainAccessPreflight.DecryptACLEvaluation = switch dynamic {
        case errSecSuccess: .allowed
        case errSecCSReqFailed: .rejected
        default: .indeterminate
        }
        #expect(result == (dynamic == errSecCSReqFailed ? OSStatus(CSSMERR_CSP_VERIFY_FAILED) : dynamic))
        #expect(KeychainAccessPreflight.evaluateDecryptACL(
            trustedApplicationValidationStatuses: [result], promptSelector: []) == expected)
        #expect(KeychainAccessPreflight.evaluateDecryptACL(
            trustedApplicationValidationStatuses: [result], promptSelector: .init(rawValue: 1)) == .rejected)
    }
}
#endif
