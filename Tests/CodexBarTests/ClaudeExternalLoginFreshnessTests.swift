import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import LocalAuthentication
import Security

@Suite(ClaudeOAuthDefaultsFixtures())
struct ClaudeExternalLoginFreshnessTests {
    private static let failureDate = Date(timeIntervalSince1970: 1_600_000_000)
    private static let loginDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `without consent new Keychain metadata names the consent toggle without requesting the payload`() throws {
        try self.withFixture { _, environment, key in
            ClaudeOAuthDefaultsFixtures.defaults.set(Self.failureDate, forKey: key)
            self.withMetadata(Self.loginDate) {
                for _ in 0..<2 {
                    let error = self.loadError(environment)
                    guard case let .directKeychainReadNotAllowed(changedAt) = error else {
                        Issue.record("Refresh cannot read Claude Code's Keychain item without consent")
                        return
                    }
                    let message = error.localizedDescription
                    #expect(changedAt == Self.loginDate)
                    #expect(message.contains("Claude Code credentials changed"))
                    #expect(message.contains("Allow reading Claude Code's credentials"))
                    #expect(!message.contains("re-grant"))
                    #expect(message.contains("update once through the Claude CLI"))
                    #expect(!message.contains("Run `claude`"))
                    #expect(ClaudeOAuthCredentialsError.isDirectKeychainReadNotAllowed(description: message))
                    #expect(ClaudeOAuthDefaultsFixtures.defaults.object(forKey: key) as? Date == Self.failureDate)
                }
            }
        }
    }

    @Test
    func `with consent new Keychain metadata keeps the Refresh guidance`() throws {
        try self.withFixture(consent: true) { _, environment, _ in
            self.withMetadata(Self.loginDate) {
                let error = ClaudeOAuthCredentialsStore.credentialChangeError(
                    since: Self.failureDate,
                    environment: environment)
                guard case let .credentialsChanged(changedAt) = error else {
                    Issue.record("Refresh can read the changed Keychain item once consent is granted")
                    return
                }
                #expect(changedAt == Self.loginDate)
                #expect(error?.localizedDescription.contains("Click Refresh") == true)
                #expect(!ClaudeOAuthCredentialsError.isDirectKeychainReadNotAllowed(
                    description: error?.localizedDescription))
            }
        }
    }

    @Test(arguments: [false, true])
    func `a newer credentials file offers Refresh and only consent lets Keychain metadata feed it`(
        consent: Bool) throws
    {
        let keychainDate = Self.loginDate.addingTimeInterval(100)
        try self.withFixture(consent: consent) { file, environment, _ in
            try Data("metadata only".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Self.loginDate], ofItemAtPath: file.path)
            for metadata in [Self.failureDate, keychainDate] {
                self.withMetadata(metadata) {
                    let error = ClaudeOAuthCredentialsStore.credentialChangeError(
                        since: Self.failureDate,
                        environment: environment)
                    guard case let .credentialsChanged(changedAt) = error else {
                        Issue.record("A file change is readable without Keychain consent")
                        return
                    }
                    #expect(changedAt == (consent && metadata == keychainDate ? keychainDate : Self.loginDate))
                }
            }
        }
    }

    @Test(arguments: [nil, Self.failureDate, Self.failureDate.addingTimeInterval(-1), Date.distantFuture])
    func `absent older equal and future metadata do not claim a new login`(date: Date?) throws {
        try self.withFixture { _, environment, key in
            ClaudeOAuthDefaultsFixtures.defaults.set(Self.failureDate, forKey: key)
            self.withMetadata(date) {
                guard case .notFound = self.loadError(environment) else {
                    Issue.record("Only a newer observed timestamp may replace the missing-credential error")
                    return
                }
            }
        }
    }

    @Test
    func `first failure records a baseline and readable credentials clear it`() throws {
        try self.withFixture { file, environment, key in
            _ = self.loadError(environment)
            #expect(ClaudeOAuthDefaultsFixtures.defaults.object(forKey: key) is Date)
            try Data("""
            {"claudeAiOauth":{"accessToken":"synthetic-external-login",
            "expiresAt":4102444800000,"scopes":["user:profile"]}}
            """.utf8).write(to: file)
            _ = try ClaudeOAuthCredentialsStore.loadRecord(environment: environment, allowKeychainPrompt: false)
            #expect(ClaudeOAuthDefaultsFixtures.defaults.object(forKey: key) == nil)
        }
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecItemNotFound])
    func `unavailable metadata fails soft without reading a credential`(queryStatus: OSStatus) throws {
        try self.withFixture { _, environment, key in
            ClaudeOAuthDefaultsFixtures.defaults.set(Self.failureDate, forKey: key)
            self.withMetadata(Self.loginDate, queryStatus: queryStatus) {
                guard case .notFound = self.loadError(environment) else {
                    Issue.record("Failed metadata queries must not assert that a login happened")
                    return
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func `file mtime is available with Keychain disabled and custom profiles ignore the global item`(
        customProfile: Bool) throws
    {
        try self.withFixture(customProfile: customProfile) { file, environment, _ in
            try Data("not a credential payload".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Self.loginDate], ofItemAtPath: file.path)
            let unexpectedQuery: @Sendable ([String: Any]) -> (OSStatus, AnyObject?, Double) = { _ in
                Issue.record("This profile must not query the global Keychain item")
                return (errSecSuccess, nil, 0)
            }
            KeychainAccessGate.withTaskOverrideForTesting(!customProfile) {
                ClaudeOAuthKeychainQueryTiming.$copyMatchingOverride.withValue(unexpectedQuery) {
                    let dates = ClaudeOAuthCredentialsStore.credentialModificationDates(environment: environment)
                    #expect(dates.file == Self.loginDate)
                    #expect(dates.keychain == nil)
                }
            }
        }
    }

    @Test
    func `freshness reports the file and newest matching item without a persistent reference`() throws {
        try self.withFixture { file, environment, _ in
            try Data("metadata only".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Self.failureDate], ofItemAtPath: file.path)
            self.withMetadata(Self.loginDate) {
                let dates = ClaudeOAuthCredentialsStore.credentialModificationDates(environment: environment)
                #expect(dates.file == Self.failureDate)
                #expect(dates.keychain == Self.loginDate)
            }
        }
    }

    private func withFixture(
        customProfile: Bool = false,
        consent: Bool = false,
        operation: (URL, [String: String], String) throws -> Void) throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(customProfile ? "custom" : ".claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent(".credentials.json")
        var environment = ["HOME": root.path]
        if customProfile { environment["CLAUDE_CONFIG_DIR"] = directory.path }
        try KeychainCacheStore.withServiceOverrideForTesting("synthetic-login-\(UUID())") {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(file) {
                let profile = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
                try KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                            try ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(consent) {
                                try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                                    try ProviderInteractionContext.$current.withValue(.background) {
                                        try ClaudeOAuthCredentialsStore
                                            .withClaudeKeychainFingerprintStoreOverrideForTesting(
                                                .init())
                                            {
                                                try operation(
                                                    file,
                                                    environment,
                                                    "ClaudeOAuthLastCredentialFailure." + profile)
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadError(_ environment: [String: String]) -> ClaudeOAuthCredentialsError {
        do {
            _ = try ClaudeOAuthCredentialsStore.loadRecord(environment: environment, allowKeychainPrompt: false)
            Issue.record("Missing credentials must remain a failure until explicit Refresh")
        } catch let error as ClaudeOAuthCredentialsError {
            return error
        } catch {
            Issue.record("Unexpected credential failure type")
        }
        return .notFound
    }

    private func withMetadata(_ date: Date?, queryStatus: OSStatus = errSecSuccess, operation: () -> Void) {
        ClaudeOAuthKeychainQueryTiming.$copyMatchingOverride.withValue({ query in
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "Claude Code-credentials")
            #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String)
            #expect(query[kSecReturnAttributes as String] as? Bool == true)
            #expect(query[kSecReturnData as String] == nil)
            #expect(query[kSecReturnRef as String] == nil)
            #expect(query[kSecReturnPersistentRef as String] == nil)
            #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
            #expect(query[kSecUseAuthenticationUI as String] as? String == KeychainNoUIQuery.uiFailPolicyForTesting())
            let rows: [[String: Any]] = date.map {
                [[kSecAttrModificationDate as String: Self.failureDate], [kSecAttrModificationDate as String: $0]]
            } ?? []
            return (queryStatus, rows as NSArray, 0)
        }, operation: operation)
    }
}
#endif
