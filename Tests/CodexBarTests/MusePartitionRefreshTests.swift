#if os(macOS)
import Foundation
import Security
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct MusePartitionRefreshTests {
    @Test
    func `provider refresh explains one excluded partition read only for a manual action`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        try Data(#"{"providers":{"meta":{"mechanism":"oauth","storage":"keychain"}}}"#.utf8).write(to: file)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: ["MUSE_AUTH_PATH": file.path],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(
                browserDetection: BrowserDetection(homeDirectory: home.path),
                environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: home.path))
        let events = LockIsolated<[String]>([])
        let descriptions = try [KeychainAccessPreflightPartitionTests.description(["teamid:OTHER"])]
        await BrowserCookieAccessGate.withIsolatedStateForTesting {
            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await KeychainAccessPreflight.withPartitionCheckOverrideForTesting { service, _, requirePartition in
                    #expect(service == MuseCredentials.keychainService)
                    guard requirePartition else { return .allowed }
                    let result = KeychainAccessPreflight.evaluatePartitionList(
                        descriptions: descriptions, callerTeam: "OURS")
                    return result == .rejected ? .interactionRequired : .temporarilyUnavailable
                } operation: {
                    await KeychainPromptHandler.withHandlerForTesting { context in
                        #expect(context.kind == .museToken)
                        events.setValue(events.value + ["explain"])
                    } operation: {
                        let read: @Sendable ([String: Any]) -> (OSStatus, Data?) = { query in
                            events.setValue(events.value + [
                                query[kSecUseAuthenticationContext as String] == nil ? "interactive" : "no-ui",
                            ])
                            // Stop before HTTP and establish the denial cooldown without a real Keychain read.
                            return (errSecUserCanceled, nil)
                        }
                        await MuseCredentials.$keychainReadOverrideForTesting.withValue(read) {
                            @Sendable func refresh() async {
                                let result = await MuseProviderDescriptor.descriptor.fetchOutcome(context: context)
                                #expect(throws: (any Error).self) { try result.result.get() }
                            }
                            await ProviderInteractionContext.$current.withValue(.background) { await refresh() }
                            #expect(events.value.isEmpty)
                            await BrowserCookieAccessGate.withExplicitRetry {
                                await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                    let settingsRefresh = BrowserCookieKeychainAccessGate
                                        .withUserInteractionDisallowed {
                                            Task { await refresh() }
                                        }
                                    await settingsRefresh.value
                                    #expect(events.value.isEmpty)
                                    await refresh()
                                    #expect(events.value == ["explain", "interactive"])
                                    await refresh()
                                    #expect(events.value == ["explain", "interactive"])
                                }
                            }
                            await BrowserCookieAccessGate.withExplicitRetry {
                                await ProviderInteractionContext.$current.withValue(.userInitiated) { await refresh() }
                            }
                            #expect(events.value == ["explain", "interactive"])
                        }
                    }
                }
            }
        }
    }
}
#endif
