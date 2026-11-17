import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore
#if os(macOS)
import SweetCookieKit
#endif

struct QoderProviderBehaviorTests {
    @MainActor
    private final class SessionQuotaNotifierSpy: SessionQuotaNotifying {
        private(set) var posts: [(transition: SessionQuotaTransition, provider: UsageProvider)] = []
        private(set) var quotaWarningPosts: [(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)] = []

        func post(transition: SessionQuotaTransition, provider: UsageProvider, badge _: NSNumber?) {
            self.posts.append((transition: transition, provider: provider))
        }

        func postQuotaWarning(
            event: QuotaWarningEvent,
            provider: UsageProvider,
            soundEnabled: Bool,
            onScreenAlertEnabled: Bool)
        {
            self.quotaWarningPosts.append((
                event: event,
                provider: provider,
                soundEnabled: soundEnabled,
                onScreenAlertEnabled: onScreenAlertEnabled))
        }
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `token account selection forces manual cookie source in CLI settings snapshot`() throws {
        let accounts = ProviderTokenAccountData(
            version: 1,
            accounts: [
                ProviderTokenAccount(
                    id: UUID(),
                    label: "Qoder",
                    token: "sid=qoder-account-token",
                    addedAt: 0,
                    lastUsed: nil),
            ],
            activeIndex: 0)
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .qoder,
                cookieSource: .auto,
                tokenAccounts: accounts),
        ])
        let selection = TokenAccountCLISelection(label: nil, index: nil, allAccounts: false)
        let tokenContext = try TokenAccountCLIContext(selection: selection, config: config, verbose: false)
        let account = try #require(tokenContext.resolvedAccounts(for: .qoder).first)
        let snapshot = try #require(tokenContext.settingsSnapshot(for: .qoder, account: account))
        let qoderSettings = try #require(snapshot.qoder)

        #expect(qoderSettings.cookieSource == .manual)
        #expect(qoderSettings.manualCookieHeader == "sid=qoder-account-token")
    }

    @Test
    func `model shows credit total only as primary detail when reset date missing`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.qoder])
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "125 / 500 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))

        let model = UsageMenuCardView.Model.make(.init(
            provider: .qoder,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText == nil)
        #expect(primary.detailText == "125 / 500 credits")
        #expect(model.creditsText == nil)
        #expect(model.creditsHintText == nil)
    }

    @Test
    func `model shows reset countdown with credit detail`() throws {
        let now = Date(timeIntervalSince1970: 1_719_206_400)
        let snapshot = QoderUsageSnapshot(
            usedCredits: 125,
            totalCredits: 500,
            remainingCredits: 375,
            usagePercentage: 25,
            unit: "credit",
            resetsAt: now.addingTimeInterval(86400),
            updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.qoder])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .qoder,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.resetText != nil)
        #expect(primary.detailText == "125 / 500 credits")
    }

    @MainActor
    @Test
    func `menu shows add-on credits detail and automatic selection prefers the remaining pool`() {
        let suite = "QoderProviderBehaviorTests-add-on-menu"
        let defaults = InMemoryUserDefaults()

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_719_206_400)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(86400),
                resetDescription: "0 / 0 credits"),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "5,000 / 5,000 credits"),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "qoder-add-on",
                    title: "Add-on credits",
                    window: RateWindow(
                        usedPercent: 24,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: "1,200 / 5,000 credits")),
            ],
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        store._setSnapshotForTesting(snapshot, provider: .qoder)

        let descriptor = MenuDescriptor.build(
            provider: .qoder,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }
        #expect(textLines.contains("1,200 / 5,000 credits"))
        #expect(!textLines.contains(where: { $0.contains("Resets 1,200 / 5,000 credits") }))
        #expect(textLines.contains("5,000 / 5,000 credits"))

        let selected = MenuBarMetricWindowResolver.rateWindow(
            preference: .automatic,
            provider: .qoder,
            snapshot: snapshot,
            supportsAverage: false,
            now: now)
        #expect(selected?.usedPercent == 24)
    }

    @MainActor
    @Test
    func `standard menu shows credit total as detail instead of reset line`() throws {
        let suite = "QoderProviderBehaviorTests-menu-detail"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "125 / 500 credits"),
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        store._setSnapshotForTesting(snapshot, provider: .qoder)

        let descriptor = MenuDescriptor.build(
            provider: .qoder,
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updateReady: false,
            includeContextualActions: false)

        let textLines = descriptor.sections
            .flatMap(\.entries)
            .compactMap { entry -> String? in
                guard case let .text(text, _) = entry else { return nil }
                return text
            }

        #expect(textLines.contains("125 / 500 credits"))
        #expect(!textLines.contains(where: { $0.contains("Resets 125 / 500 credits") }))
    }

    @MainActor
    @Test
    func `menu card shows the secondary credit balance without a reset prefix`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .qoder)
        let now = Date(timeIntervalSince1970: 1_719_206_400)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "0 / 0 credits",
                title: "Plan credits"),
            secondary: RateWindow(
                usedPercent: 24,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "1,200 / 5,000 credits",
                title: "Organization resource package"),
            updatedAt: now,
            identity: ProviderIdentitySnapshot(
                providerID: .qoder,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        let model = UsageMenuCardView.Model.make(.init(
            provider: .qoder,
            metadata: descriptor.metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            weeklyPace: nil,
            now: now))

        let secondary = try #require(model.metrics.first { $0.title == "Organization resource package" })
        #expect(secondary.detailText == "1,200 / 5,000 credits")
        #expect(secondary.resetText == nil)
        #expect(!(secondary.detailText ?? "").hasPrefix("Resets"))
    }
}

struct QoderManualCookieRoutingTests {
    @Test
    func `manual cookie header can route to Qoder China site`() {
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sid=abc") == .international)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sid=qoder.com.cn-looking-value") == .international)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "sid=abc; note=curl https://qoder.com.cn") == .international)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "sid=abc; redirect=https://example.com/curl") == .international)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sid=abc; Domain=.qoder.com.cn") == .china)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sid=abc; Domain=qoder.com.cn") == .china)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sid=abc; Domain=www.qoder.com.cn") == .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "HTTPS_PROXY=http://127.0.0.1:8080 curl https://qoder.com.cn") == .china)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "HTTPS_PROXY=http://127.0.0.1:8080 \\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'") ==
            .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "\\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "\\\r\ncurl https://qoder.com -H 'Cookie: sid=abc'") == .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'Origin: https://qoder.com' " +
                    "-H 'Referer: https://qoder.com/account/usage' -H 'Cookie: sid=abc'") == .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Origin: https://qoder.com.cn' " +
                    "-H 'Referer: https://qoder.com.cn/account/usage' -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl https://www.qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl --url https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl --url https://qoder.com --data 'x=1; Domain=qoder.com.cn'") ==
            .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --data 'GET /account/usage HTTP/1.1\nHost: qoder.com.cn'") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "GET https://qoder.com.cn/account/usage") == .china)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn") ==
            .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: www.qoder.com.cn") ==
            .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:443") ==
            .china)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:evil") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:65536") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:443:444") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com") ==
            .international)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "TRACE /account/usage HTTP/1.1\nHost: qoder.com.cn") ==
            nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "CONNECT qoder.com.cn:443 HTTP/1.1") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "BREW /account/usage HTTP/1.1\nHost: qoder.com.cn") ==
            nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl -H 'Referer: https://qoder.com.cn/account/usage' https://qoder.com -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl --proxy-header 'X: https://qoder.com.cn' https://qoder.com -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "curl -X GET https://qoder.com.cn") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sudo curl https://qoder.com.cn") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "sid=abc; curl https://qoder.com.cn") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl https://qoder.com/account https://qoder.com/profile") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl --url https://qoder.com/account https://qoder.com/profile") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl https://qoder.com https://qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "curl https://example.com -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET https://qoder.com/account/usage HTTP/1.1\nHost: qoder.com.cn") == nil)
        #expect(QoderCookieRouting
            .site(forManualCookieHeader: "GET https://qoder.com/account/usage HTTP/1.1\nHost: example.com") == nil)
        #expect(QoderCookieRouting.site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: example.com") ==
            nil)
    }

    @Test
    func `manual curl Host headers must match authoritative Qoder target`() {
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'Host: qoder.com' -H 'Cookie: sid=abc'") == .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: www.qoder.com.cn:443' -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -sH 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -fsSLHHost:qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -HHost:qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --header=Host:qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn \\\n-H 'Host: qoder.com.cn' \\\r\n-H 'Cookie: sid=abc'") == .china)

        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: qoder.com' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: qoder.com.cn:evil' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: qoder.com.cn' -H 'Host: qoder.com' -H 'Cookie: sid=abc'") ==
            nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -sH 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -fsSLHHost:qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -HHost:qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -XH 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H @headers.txt -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --header @- -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host:' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host;' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --header=Host\\; -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -sHHost\\; -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -K qoder.curlrc -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --config qoder.curlrc -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --config=qoder.curlrc -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --variable site=qoder.com.cn --expand-header 'Host: {{site}}' " +
                    "-H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --variable site=qoder.com.cn --expand-url 'https://{{site}}' " +
                    "-H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --expand-config '{{config}}' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn ; echo -H 'Cookie: sid=global'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn | cat -H 'Cookie: sid=global'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn > headers.txt -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com && echo done -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl 'https://qoder.com/account/usage?a=1&b=2;next=ok' -H 'Cookie: sid=abc'") ==
            .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'X-Note: a;b|c&d=<e>' -H 'Cookie: sid=abc'") == .international)
    }

    @Test
    func `manual curl rejects shell synthesis and injected controls`() {
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --location-trusted -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $'agent\r\nHost: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --referer $'https://qoder.com\r\nHost: qoder.com.cn' " +
                    "-H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\'$'agent\\r\\nHost: qoder.com.cn'\\' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\'$'agent\r\nHost: qoder.com.cn'\\' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'User-Agent: agent\\\nHost: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $'agent\\r\\nHost: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $(printf agent) -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A `printf agent` -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "\"curl\" https://qoder.com.cn -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "'/usr/bin/curl' https://qoder.com.cn -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "\\curl https://qoder.com.cn -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "QODER_AGENT=$AGENT \\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H \"User-Agent: $AGENT\" -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $\"agent\" -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H @<(printf 'Host: qoder.com.cn') -H 'Cookie: sid=abc'") == nil)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\'literal\\' -H 'Cookie: sid=abc'") == .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\\"literal\\\" -H 'Cookie: sid=abc'") == .international)
        #expect(QoderCookieRouting
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A literal\\\\slash -H 'Cookie: sid=abc'") == .international)
    }
}

extension QoderProviderBehaviorTests {
    #if os(macOS)
    @Test
    func `importer exact domain filter keeps China cookies out of global sessions`() {
        let records = [
            Self.cookieRecord(domain: "qoder.com", name: "global", value: "1"),
            Self.cookieRecord(domain: ".qoder.com.cn", name: "china", value: "1"),
            Self.cookieRecord(domain: "www.qoder.com.cn", name: "china-www", value: "1"),
        ]

        let filtered = records
            .filter { ProviderPluginCookieBroker.matches(cookieDomain: $0.domain, domain: "qoder.com") }

        #expect(ProviderPluginCookieBroker.cookieQuery(domain: "qoder.com").domainMatch == .exact)
        #expect(filtered.map(\.name) == ["global"])
    }

    @Test
    func `importer exact domain filter keeps global cookies out of China sessions`() {
        let records = [
            Self.cookieRecord(domain: ".qoder.com", name: "global", value: "1"),
            Self.cookieRecord(domain: "qoder.com.cn", name: "china", value: "1"),
            Self.cookieRecord(domain: ".www.qoder.com.cn", name: "china-www", value: "1"),
        ]

        let filtered = records.filter { ProviderPluginCookieBroker.matches(
            cookieDomain: $0.domain,
            domain: "qoder.com.cn") }

        #expect(ProviderPluginCookieBroker.cookieQuery(domain: "qoder.com.cn").domainMatch == .exact)
        #expect(filtered.map(\.name) == ["china", "china-www"])
    }
    #endif

    @Test
    @MainActor
    func `monthly credits keep nil cadence and do not emit quota notifications`() throws {
        let suiteName = "QoderProviderBehaviorTests-quota-notifications"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.sessionQuotaNotificationsEnabled = true
        settings.quotaWarningNotificationsEnabled = true
        settings.quotaWarningThresholds = [50, 20]

        let notifier = SessionQuotaNotifierSpy()
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionQuotaNotifier: notifier)
        let depletedSnapshot = QoderUsageSnapshot(
            usedCredits: 500,
            totalCredits: 500,
            remainingCredits: 0,
            usagePercentage: 100,
            unit: "credit",
            resetsAt: Date().addingTimeInterval(30 * 24 * 60 * 60))
            .toUsageSnapshot()
        let restoredSnapshot = QoderUsageSnapshot(
            usedCredits: 100,
            totalCredits: 500,
            remainingCredits: 400,
            usagePercentage: 20,
            unit: "credit",
            resetsAt: Date().addingTimeInterval(30 * 24 * 60 * 60))
            .toUsageSnapshot()
        let restoredPrimary = try #require(restoredSnapshot.primary)

        #expect(depletedSnapshot.primary?.windowMinutes == nil)
        #expect(restoredPrimary.windowMinutes == nil)
        #expect(store
            .weeklyPace(provider: .qoder, window: restoredPrimary, dataConfidence: .unknown, now: Date()) == nil)

        for snapshot in [depletedSnapshot, restoredSnapshot] {
            store.handleSessionQuotaTransition(provider: .qoder, snapshot: snapshot)
            store.handleQuotaWarningTransitions(provider: .qoder, snapshot: snapshot)
        }

        #expect(notifier.posts.isEmpty)
        #expect(notifier.quotaWarningPosts.isEmpty)
    }

    private func makeContext(settings: ProviderSettingsSnapshot?) -> ProviderFetchContext {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    #if os(macOS)
    private static func cookieRecord(domain: String, name: String, value: String) -> BrowserCookieRecord {
        BrowserCookieRecord(
            domain: domain,
            name: name,
            path: "/",
            value: value,
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: true)
    }
    #endif
}
