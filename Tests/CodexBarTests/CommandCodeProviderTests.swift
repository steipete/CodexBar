import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CommandCodeProviderTests {
    private final class CookieAttemptRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var cookieHeaders: [String] = []

        func append(_ cookieHeader: String) {
            self.lock.withLock {
                self.cookieHeaders.append(cookieHeader)
            }
        }

        func snapshot() -> [String] {
            self.lock.withLock { self.cookieHeaders }
        }
    }

    @Test
    func `descriptor metadata is correct`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .commandcode)

        #expect(descriptor.metadata.displayName == "Command Code")
        #expect(descriptor.metadata.dashboardURL == "https://commandcode.ai/studio")
        #expect(descriptor.metadata.subscriptionDashboardURL == "https://commandcode.ai/settings/billing")
        #expect(descriptor.metadata.cliName == "commandcode")
        #expect(descriptor.branding.iconResourceName == "ProviderIcon-commandcode")
        #expect(descriptor.branding.iconStyle == .commandcode)
    }

    @Test
    func `manual cookie makes web strategy available`() async {
        let context = self.makeContext(cookieSource: .manual, manualCookieHeader: "session=manual")

        #expect(await CommandCodeWebFetchStrategy().isAvailable(context))
    }

    @Test
    func `automatic cookie fetch retries Vivaldi after stale earlier browser session`() async throws {
        let recorder = CookieAttemptRecorder()
        let strategy = CommandCodeWebFetchStrategy(
            usageLoader: { cookieHeader in
                recorder.append(cookieHeader)
                guard cookieHeader == "session=vivaldi" else {
                    throw CommandCodeUsageError.invalidCredentials
                }
                return Self.snapshot()
            },
            sessionLoader: {
                [
                    CommandCodeResolvedSession(cookieHeader: "session=stale", sourceLabel: "Chrome Default"),
                    CommandCodeResolvedSession(cookieHeader: "session=vivaldi", sourceLabel: "Vivaldi Default"),
                ]
            })

        let result = try await strategy.fetch(self.makeContext(cookieSource: .auto))

        #expect(recorder.snapshot() == ["session=stale", "session=vivaldi"])
        #expect(result.sourceLabel == "Vivaldi Default")
    }

    @Test
    func `automatic cookie fetch does not hide non-auth failure with later session`() async {
        let recorder = CookieAttemptRecorder()
        let strategy = CommandCodeWebFetchStrategy(
            usageLoader: { cookieHeader in
                recorder.append(cookieHeader)
                throw CommandCodeUsageError.networkError("offline")
            },
            sessionLoader: {
                [
                    CommandCodeResolvedSession(cookieHeader: "session=first", sourceLabel: "Chrome Default"),
                    CommandCodeResolvedSession(cookieHeader: "session=vivaldi", sourceLabel: "Vivaldi Default"),
                ]
            })

        await #expect(throws: CommandCodeUsageError.networkError("offline")) {
            try await strategy.fetch(self.makeContext(cookieSource: .auto))
        }
        #expect(recorder.snapshot() == ["session=first"])
    }

    @MainActor
    @Test
    func `implementation is registered`() {
        #expect(ProviderCatalog.implementation(for: .commandcode) != nil)
    }

    private static func snapshot() -> CommandCodeUsageSnapshot {
        CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 10,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            plan: nil,
            billingPeriodEnd: nil,
            subscriptionStatus: nil)
    }

    private func makeContext(
        cookieSource: ProviderCookieSource,
        manualCookieHeader: String? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let settings = ProviderSettingsSnapshot.make(
            commandcode: .init(cookieSource: cookieSource, manualCookieHeader: manualCookieHeader))
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .web,
            includeCredits: true,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
