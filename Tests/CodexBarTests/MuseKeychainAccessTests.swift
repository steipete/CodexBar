#if os(macOS)
import Foundation
import LocalAuthentication
import Security
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct MuseKeychainAccessTests {
    @Test
    func `missing Muse grant names the Keychain Access recovery without reading secrets`() throws {
        let run = try Self.fetchToken(outcome: .interactionRequired, interaction: .background)
        #expect(run.error?.errorDescription?.contains("Keychain Access") == true)
        #expect(run.events == ["preflight"])
    }

    @Test
    func `temporary Muse Keychain failure names unlocking rather than a missing grant`() throws {
        let run = try Self.fetchToken(outcome: .temporarilyUnavailable, interaction: .userInitiated)
        #expect(run.error?.errorDescription?.contains("unlock") == true)
        #expect(run.events.allSatisfy { $0 == "preflight" })
    }

    @Test
    func `manual refresh can grant access to the Muse login`() throws {
        let run = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated)
        #expect(run.token == "dca:fixture-keychain")
        #expect(run.error == nil)
        #expect(run.events == ["preflight", "explain museToken", "read interactive"])
    }

    @Test
    func `settings no UI policy prevents a Muse grant inside a manual scope`() throws {
        try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed {
            let run = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated)
            #expect(run.error == .keychainAccessNotGranted)
            #expect(run.events == ["preflight"])
        }
    }

    @Test
    func `repeated Muse reads share one manual action allowance`() throws {
        try BrowserCookieAccessGate.withIsolatedStateForTesting {
            try BrowserCookieAccessGate.withExplicitRetry {
                let first = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated)
                let second = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated)
                #expect(first.token != nil)
                #expect(second.error == .keychainAccessNotGranted)
                #expect(second.events == ["preflight"])
            }
        }
    }

    @Test
    func `a denial suppresses a later manual action without another read`() throws {
        try BrowserCookieAccessGate.withIsolatedStateForTesting {
            let denied = try Self.fetchToken(
                outcome: .interactionRequired, interaction: .userInitiated, readStatus: errSecUserCanceled)
            let retried = try Self.fetchToken(outcome: .interactionRequired, interaction: .userInitiated)
            #expect(denied.error == .keychainAccessNotGranted)
            #expect(retried.error == .keychainAccessNotGranted)
            #expect(retried.events == ["preflight"])
        }
    }

    @Test(
        arguments: [KeychainAccessPreflight.Outcome.interactionRequired, .temporarilyUnavailable, .failure(-1)],
        [ProviderInteraction.background, .userInitiated])
    func `blocked preflight only reads interactively for a user action when access was not granted`(
        outcome: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction) throws
    {
        for hasMetadata in [false, true] {
            let run = try Self.fetchToken(
                outcome: outcome, interaction: interaction, hasMetadata: hasMetadata)
            if outcome == .interactionRequired, interaction == .userInitiated {
                #expect(run.error == nil)
                #expect(run.token == "dca:fixture-keychain")
                #expect(run.events == ["preflight", "explain museToken", "read interactive"])
            } else {
                #expect(run.error ==
                    (outcome == .interactionRequired ? .keychainAccessNotGranted : .keychainUnavailable))
                #expect(run.token == nil)
                #expect(!run.events.isEmpty)
                #expect(run.events.allSatisfy { $0 == "preflight" })
            }
        }
    }

    @Test
    func `a denied interactive read keeps the grant diagnostic`() throws {
        let run = try Self.fetchToken(
            outcome: .interactionRequired, interaction: .userInitiated, readStatus: errSecUserCanceled)
        #expect(run.error == .keychainAccessNotGranted)
        #expect(run.token == nil)
        #expect(run.events == ["preflight", "explain museToken", "read interactive"])
    }

    @Test(arguments: [errSecNotAvailable, errSecInteractionNotAllowed])
    func `a temporary interactive read failure stays unavailable instead of a denial`(readStatus: OSStatus) throws {
        let run = try Self.fetchToken(
            outcome: .interactionRequired, interaction: .userInitiated, readStatus: readStatus)
        #expect(run.error == .keychainUnavailable)
        #expect(run.token == nil)
        #expect(run.events == ["preflight", "explain museToken", "read interactive"])
    }

    @Test
    func `without an explanation alert a user action never reads interactively`() throws {
        let run = try Self.fetchToken(
            outcome: .interactionRequired, interaction: .userInitiated, explainsPrompt: false)
        #expect(run.error == .keychainAccessNotGranted)
        #expect(run.token == nil)
        #expect(run.events == ["preflight"])
    }

    @Test(arguments: [ProviderInteraction.background, .userInitiated])
    func `trusted item is read without UI or an explanation`(interaction: ProviderInteraction) throws {
        let run = try Self.fetchToken(outcome: .allowed, interaction: interaction)
        #expect(run.token == "dca:fixture-keychain")
        #expect(run.events == ["preflight", "read no-ui"])
    }

    @Test(arguments: [
        KeychainAccessPreflight.Outcome.allowed,
        .interactionRequired,
        .temporarilyUnavailable,
        .notFound,
        .failure(-1),
    ], [ProviderInteraction.background, .userInitiated])
    func `login detection never requests the secret`(
        outcome: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction) throws
    {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let events = LockIsolated<[String]>([])
        let hasLogin = Self.withSyntheticKeychain(outcome: outcome, interaction: interaction, events: events) {
            MuseCredentials.hasLogin(environment: [:], homeDirectory: home)
        }
        #expect(hasLogin ==
            (outcome == .allowed || outcome == .interactionRequired || outcome == .temporarilyUnavailable))
        #expect(!events.value.isEmpty)
        #expect(events.value.allSatisfy { $0 == "preflight" })
    }

    @Test(arguments: [ProviderInteraction.background, .userInitiated])
    func `absent Keychain item never requests a secret`(interaction: ProviderInteraction) throws {
        let run = try Self.fetchToken(outcome: .notFound, interaction: interaction)
        #expect(run.error == .missingCredentials)
        #expect(run.events == ["preflight"])
    }

    @Test(arguments: [false, true])
    func `disabled Keychain access skips preflight and secret reads`(hasMetadata: Bool) throws {
        let run = try Self.fetchToken(
            outcome: .allowed, interaction: .userInitiated, hasMetadata: hasMetadata, disabled: true)
        #expect(run.error == (hasMetadata ? .keychainAccessDisabled : .missingCredentials))
        #expect(run.events.isEmpty)

        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let events = LockIsolated<[String]>([])
        let hasLogin = Self.withSyntheticKeychain(
            outcome: .allowed, interaction: .userInitiated, events: events, disabled: true)
        {
            MuseCredentials.hasLogin(environment: [:], homeDirectory: home)
        }
        #expect(!hasLogin)
        #expect(events.value.isEmpty)
    }

    @Test
    func `metadata and inline credentials never need a Keychain query`() throws {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        let events = LockIsolated<[String]>([])
        for body in [
            #"{"providers":{"meta":{"mechanism":"oauth"}}}"#,
            #"{"providers":{"meta":{"access_token":"dca:fixture-inline"}}}"#,
        ] {
            try Data(body.utf8).write(to: file)
            Self.withSyntheticKeychain(outcome: .allowed, interaction: .userInitiated, events: events) {
                #expect(MuseCredentials.hasLogin(environment: ["MUSE_AUTH_PATH": file.path], homeDirectory: home))
            }
        }
        Self.withSyntheticKeychain(outcome: .interactionRequired, interaction: .userInitiated, events: events) {
            #expect((try? MuseCredentials.accessToken(
                environment: ["MUSE_AUTH_PATH": file.path], homeDirectory: home)) == "dca:fixture-inline")
        }
        #expect(events.value.isEmpty)
    }

    @Test(arguments: [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed])
    func `a changed Keychain item fails without an interactive retry`(readStatus: OSStatus) throws {
        let run = try Self.fetchToken(outcome: .allowed, interaction: .userInitiated, readStatus: readStatus)
        #expect(run.error == (readStatus == errSecItemNotFound ? .missingCredentials : .keychainUnavailable))
        #expect(run.events == ["preflight", "read no-ui"])
    }

    private struct Run {
        var token: String?
        var error: MuseUsageError?
        var events: [String] = []
    }

    /// Fetches the token for a Keychain-backed CLI login whose item reports `outcome` from the no-UI ACL preflight.
    private static func fetchToken(
        outcome: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction,
        hasMetadata: Bool = true,
        disabled: Bool = false,
        readStatus: OSStatus = errSecSuccess,
        explainsPrompt: Bool = true) throws -> Run
    {
        let home = try Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        if hasMetadata {
            try Data(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#.utf8).write(to: file)
        }
        let events = LockIsolated<[String]>([])
        var run = Run()
        Self.withSyntheticKeychain(
            outcome: outcome,
            interaction: interaction,
            events: events,
            disabled: disabled,
            readStatus: readStatus,
            explainsPrompt: explainsPrompt)
        {
            do {
                run.token = try MuseCredentials.accessToken(
                    environment: ["MUSE_AUTH_PATH": file.path],
                    homeDirectory: home)
            } catch let error as MuseUsageError {
                run.error = error
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        run.events = events.value
        return run
    }

    /// Records explanation alerts and secret reads in order; no real Keychain item is touched.
    private static func withSyntheticKeychain<T>(
        outcome: KeychainAccessPreflight.Outcome,
        interaction: ProviderInteraction,
        events: LockIsolated<[String]>,
        disabled: Bool = false,
        readStatus: OSStatus = errSecSuccess,
        explainsPrompt: Bool = true,
        operation: () -> T) -> T
    {
        let record: @Sendable (String) -> Void = { events.setValue(events.value + [$0]) }
        let read: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
            #expect(query[kSecAttrService as String] as? String == MuseCredentials.keychainService)
            #expect(query[kSecAttrAccount as String] as? String == MuseCredentials.keychainAccount)
            #expect(query[kSecReturnData as String] as? Bool == true)
            if let context = query[kSecUseAuthenticationContext as String] as? LAContext {
                #expect(context.interactionNotAllowed == true)
                #expect(query[kSecUseAuthenticationUI as String] as? String ==
                    KeychainNoUIQuery.uiFailPolicyForTesting())
                record("read no-ui")
            } else {
                #expect(query[kSecUseAuthenticationUI as String] == nil)
                record("read interactive")
            }
            return (readStatus, Data(#"{"access_token":"dca:fixture-keychain"}"#.utf8))
        }
        return BrowserCookieAccessGate.withIsolatedStateForTesting {
            BrowserCookieAccessGate.withExplicitRetry {
                KeychainAccessGate.withTaskOverrideForTesting(disabled) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { service, account in
                        #expect(service == MuseCredentials.keychainService)
                        #expect(account == MuseCredentials.keychainAccount)
                        record("preflight")
                        return outcome
                    } operation: {
                        KeychainPromptHandler.withHandlerForTesting(
                            explainsPrompt ? { record("explain \($0.kind)") } : nil)
                        {
                            MuseCredentials.$keychainReadOverrideForTesting.withValue(read) {
                                ProviderInteractionContext.$current.withValue(interaction, operation: operation)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}
#endif
