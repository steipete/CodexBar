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

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var cookieHeaders: [String] = []
        private var skippedLabels: [Set<String>] = []
        private var sites: [QoderWebSite] = []
        private var site: QoderWebSite?

        func appendCookieHeader(_ value: String) {
            self.lock.withLock {
                self.cookieHeaders.append(value)
            }
        }

        func appendSkippedLabels(_ value: Set<String>) {
            self.lock.withLock {
                self.skippedLabels.append(value)
            }
        }

        func setSite(_ value: QoderWebSite) {
            self.lock.withLock {
                self.site = value
            }
        }

        func appendSite(_ value: QoderWebSite) {
            self.lock.withLock {
                self.sites.append(value)
                self.site = value
            }
        }

        func cookieHeadersSnapshot() -> [String] {
            self.lock.withLock { self.cookieHeaders }
        }

        func skippedLabelsSnapshot() -> [Set<String>] {
            self.lock.withLock { self.skippedLabels }
        }

        func siteSnapshot() -> QoderWebSite? {
            self.lock.withLock { self.site }
        }

        func sitesSnapshot() -> [QoderWebSite] {
            self.lock.withLock { self.sites }
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
            dashboard: nil,
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
            dashboard: nil,
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
}

struct QoderManualCookieRoutingTests {
    @Test
    func `manual cookie header can route to Qoder China site`() {
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc") == .international)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=qoder.com.cn-looking-value") == .international)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "sid=abc; note=curl https://qoder.com.cn") == .international)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "sid=abc; redirect=https://example.com/curl") == .international)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc; Domain=.qoder.com.cn") == .china)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc; Domain=qoder.com.cn") == .china)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc; Domain=www.qoder.com.cn") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "HTTPS_PROXY=http://127.0.0.1:8080 curl https://qoder.com.cn") == .china)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "HTTPS_PROXY=http://127.0.0.1:8080 \\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'") ==
            .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "\\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "\\\r\ncurl https://qoder.com -H 'Cookie: sid=abc'") == .international)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'Origin: https://qoder.com' " +
                    "-H 'Referer: https://qoder.com/account/usage' -H 'Cookie: sid=abc'") == .international)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Origin: https://qoder.com.cn' " +
                    "-H 'Referer: https://qoder.com.cn/account/usage' -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl https://www.qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl --url https://qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl --url https://qoder.com --data 'x=1; Domain=qoder.com.cn'") ==
            .international)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --data 'GET /account/usage HTTP/1.1\nHost: qoder.com.cn'") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "GET https://qoder.com.cn/account/usage") == .china)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn") ==
            .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: www.qoder.com.cn") ==
            .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:443") ==
            .china)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:evil") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:65536") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com.cn:443:444") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: qoder.com") ==
            .international)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "TRACE /account/usage HTTP/1.1\nHost: qoder.com.cn") ==
            nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "CONNECT qoder.com.cn:443 HTTP/1.1") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "BREW /account/usage HTTP/1.1\nHost: qoder.com.cn") ==
            nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl -H 'Referer: https://qoder.com.cn/account/usage' https://qoder.com -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl --proxy-header 'X: https://qoder.com.cn' https://qoder.com -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "curl -X GET https://qoder.com.cn") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sudo curl https://qoder.com.cn") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "sid=abc; curl https://qoder.com.cn") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl https://qoder.com/account https://qoder.com/profile") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl --url https://qoder.com/account https://qoder.com/profile") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl https://qoder.com https://qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "curl https://example.com -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET https://qoder.com/account/usage HTTP/1.1\nHost: qoder.com.cn") == nil)
        #expect(QoderWebFetchStrategy
            .site(forManualCookieHeader: "GET https://qoder.com/account/usage HTTP/1.1\nHost: example.com") == nil)
        #expect(QoderWebFetchStrategy.site(forManualCookieHeader: "GET /account/usage HTTP/1.1\nHost: example.com") ==
            nil)
    }

    @Test
    func `manual curl Host headers must match authoritative Qoder target`() {
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'Host: qoder.com' -H 'Cookie: sid=abc'") == .international)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: www.qoder.com.cn:443' -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -sH 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -fsSLHHost:qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -HHost:qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --header=Host:qoder.com.cn -H 'Cookie: sid=abc'") == .china)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn \\\n-H 'Host: qoder.com.cn' \\\r\n-H 'Cookie: sid=abc'") == .china)

        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: qoder.com' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: qoder.com.cn:evil' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host: qoder.com.cn' -H 'Host: qoder.com' -H 'Cookie: sid=abc'") ==
            nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -sH 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -fsSLHHost:qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -HHost:qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -XH 'Host: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H @headers.txt -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --header @- -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host:' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -H 'Host;' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --header=Host\\; -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -sHHost\\; -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn -K qoder.curlrc -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --config qoder.curlrc -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --config=qoder.curlrc -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --variable site=qoder.com.cn --expand-header 'Host: {{site}}' " +
                    "-H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --variable site=qoder.com.cn --expand-url 'https://{{site}}' " +
                    "-H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn --expand-config '{{config}}' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn ; echo -H 'Cookie: sid=global'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn | cat -H 'Cookie: sid=global'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com.cn > headers.txt -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com && echo done -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl 'https://qoder.com/account/usage?a=1&b=2;next=ok' -H 'Cookie: sid=abc'") ==
            .international)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'X-Note: a;b|c&d=<e>' -H 'Cookie: sid=abc'") == .international)
    }

    @Test
    func `manual curl rejects shell synthesis and injected controls`() {
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --location-trusted -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $'agent\r\nHost: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com --referer $'https://qoder.com\r\nHost: qoder.com.cn' " +
                    "-H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\'$'agent\\r\\nHost: qoder.com.cn'\\' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\'$'agent\r\nHost: qoder.com.cn'\\' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H 'User-Agent: agent\\\nHost: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $'agent\\r\\nHost: qoder.com.cn' -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $(printf agent) -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A `printf agent` -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "\"curl\" https://qoder.com.cn -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "'/usr/bin/curl' https://qoder.com.cn -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "\\curl https://qoder.com.cn -A $AGENT -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "QODER_AGENT=$AGENT \\\ncurl https://qoder.com.cn -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H \"User-Agent: $AGENT\" -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A $\"agent\" -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -H @<(printf 'Host: qoder.com.cn') -H 'Cookie: sid=abc'") == nil)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\'literal\\' -H 'Cookie: sid=abc'") == .international)
        #expect(QoderWebFetchStrategy
            .site(
                forManualCookieHeader:
                "curl https://qoder.com -A \\\"literal\\\" -H 'Cookie: sid=abc'") == .international)
        #expect(QoderWebFetchStrategy
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

        let filtered = QoderCookieImporter.records(records, for: .international)

        #expect(QoderCookieImporter.cookieQuery(for: .international).domainMatch == .exact)
        #expect(filtered.map(\.name) == ["global"])
    }

    @Test
    func `importer exact domain filter keeps global cookies out of China sessions`() {
        let records = [
            Self.cookieRecord(domain: ".qoder.com", name: "global", value: "1"),
            Self.cookieRecord(domain: "qoder.com.cn", name: "china", value: "1"),
            Self.cookieRecord(domain: ".www.qoder.com.cn", name: "china-www", value: "1"),
        ]

        let filtered = QoderCookieImporter.records(records, for: .china)

        #expect(QoderCookieImporter.cookieQuery(for: .china).domainMatch == .exact)
        #expect(filtered.map(\.name) == ["china", "china-www"])
    }
    #endif

    @Test
    func `auto cookie fetch retries every imported candidate before succeeding`() async throws {
        let candidates = [
            QoderResolvedCookie(cookieHeader: "sid=expired-one", sourceLabel: "Chrome Default / qoder.com"),
            QoderResolvedCookie(cookieHeader: "sid=expired-two", sourceLabel: "Chrome Profile 2 / qoder.com.cn"),
            QoderResolvedCookie(cookieHeader: "sid=valid", sourceLabel: "Chrome Profile 3 / qoder.com.cn"),
        ]
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, _, _ in
                recorder.appendCookieHeader(cookieHeader)
                if cookieHeader != "sid=valid" {
                    throw QoderUsageError.invalidCredentials
                }
                return QoderUsageSnapshot(
                    usedCredits: 125,
                    totalCredits: 500,
                    remainingCredits: 375,
                    usagePercentage: 25,
                    unit: "credit")
            },
            cookieResolver: { _, _, skippedLabels in
                recorder.appendSkippedLabels(skippedLabels)
                return candidates.first { !skippedLabels.contains($0.sourceLabel) }
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(cookieSource: .auto, manualCookieHeader: nil))))

        #expect(recorder.cookieHeadersSnapshot() == ["sid=expired-one", "sid=expired-two", "sid=valid"])
        #expect(recorder.skippedLabelsSnapshot() == [
            Set<String>(),
            ["Chrome Default / qoder.com"],
            ["Chrome Default / qoder.com", "Chrome Profile 2 / qoder.com.cn"],
        ])
        #expect(result.sourceLabel == "Chrome Profile 3 / qoder.com.cn")
        #expect(result.usage.primary?.resetDescription == "125 / 500 credits")
    }

    @Test
    func `auto cookie source label trusts authoritative suffix over browser label text`() async throws {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                return QoderUsageSnapshot(
                    usedCredits: 125,
                    totalCredits: 500,
                    remainingCredits: 375,
                    usagePercentage: 25,
                    unit: "credit")
            },
            cookieResolver: { _, _, _ in
                QoderResolvedCookie(
                    cookieHeader: "sid=global",
                    sourceLabel: "Chrome Profile qoder.com.cn / qoder.com")
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(cookieSource: .auto, manualCookieHeader: nil))))

        #expect(recorder.sitesSnapshot() == [.international])
        #expect(result.sourceLabel == "Chrome Profile qoder.com.cn / qoder.com")
    }

    @Test
    func `auto cookie fetch retries freshly imported session after stale cache`() async throws {
        let sourceLabel = "Chrome Default / qoder.com"
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, _, _ in
                recorder.appendCookieHeader(cookieHeader)
                if cookieHeader == "sid=expired-cache" {
                    throw QoderUsageError.invalidCredentials
                }
                return QoderUsageSnapshot(
                    usedCredits: 125,
                    totalCredits: 500,
                    remainingCredits: 375,
                    usagePercentage: 25,
                    unit: "credit")
            },
            cookieResolver: { _, allowCached, skippedLabels in
                recorder.appendSkippedLabels(skippedLabels)
                if allowCached {
                    return QoderResolvedCookie(
                        cookieHeader: "sid=expired-cache",
                        sourceLabel: sourceLabel,
                        isFromCache: true)
                }
                return QoderResolvedCookie(cookieHeader: "sid=fresh", sourceLabel: sourceLabel)
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(cookieSource: .auto, manualCookieHeader: nil))))

        #expect(recorder.cookieHeadersSnapshot() == ["sid=expired-cache", "sid=fresh"])
        #expect(recorder.skippedLabelsSnapshot() == [Set<String>(), Set<String>()])
        #expect(result.sourceLabel == sourceLabel)
    }

    @Test
    func `manual cookie fetch uses China endpoint when header identifies China site`() async throws {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.setSite(site)
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(
                cookieSource: .manual,
                manualCookieHeader: "curl https://qoder.com.cn -H 'Cookie: sid=china'"))))

        #expect(recorder.siteSnapshot() == .china)
        #expect(result.sourceLabel == "manual / qoder.com.cn")
    }

    @Test
    func `manual cookie value that looks like China domain stays on global endpoint`() async throws {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        let result = try await strategy.fetch(self.makeContext(settings: .make(
            qoder: .init(
                cookieSource: .manual,
                manualCookieHeader: "sid=qoder.com.cn-looking-value"))))

        #expect(recorder.sitesSnapshot() == [.international])
        #expect(result.sourceLabel == "manual / qoder.com")
    }

    @Test
    func `manual request-like cookie with ambiguous target fails before request`() async {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        await #expect(throws: QoderUsageError.invalidCredentials) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "curl --proxy-header 'X: https://qoder.com.cn' https://qoder.com"))))
        }

        #expect(recorder.sitesSnapshot().isEmpty)
    }

    @Test
    func `manual curl with appended command does not resolve cookie or send request`() async {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, site, _ in
                recorder.appendCookieHeader(cookieHeader)
                recorder.appendSite(site)
                return QoderUsageSnapshot(
                    usedCredits: 0,
                    totalCredits: 300,
                    remainingCredits: 300,
                    usagePercentage: 0,
                    unit: "credit")
            })

        await #expect(throws: QoderUsageError.invalidCredentials) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "curl https://qoder.com.cn ; echo -H 'Cookie: sid=global'"))))
        }

        #expect(recorder.cookieHeadersSnapshot().isEmpty)
        #expect(recorder.sitesSnapshot().isEmpty)
    }

    @Test
    func `manual plain cookie fetch does not retry China after global auth failure`() async {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                throw QoderUsageError.invalidCredentials
            })

        await #expect(throws: QoderUsageError.invalidCredentials) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "sid=plain-cookie"))))
        }

        #expect(recorder.sitesSnapshot() == [.international])
    }

    @Test
    func `manual plain cookie fetch does not retry China after global network failure`() async {
        let recorder = Recorder()
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, site, _ in
                recorder.appendSite(site)
                throw QoderUsageError.networkError("timed out")
            })

        await #expect(throws: QoderUsageError.networkError("timed out")) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "sid=plain-cookie"))))
        }

        #expect(recorder.sitesSnapshot() == [.international])
    }

    @Test
    func `auto cookie fetch preserves invalid credentials when fresh import is exhausted`() async {
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, _, _ in
                throw QoderUsageError.invalidCredentials
            },
            cookieResolver: { _, allowCached, _ in
                if allowCached {
                    return QoderResolvedCookie(
                        cookieHeader: "sid=expired-cache",
                        sourceLabel: "Chrome Default / qoder.com",
                        isFromCache: true)
                }
                throw QoderUsageError.missingCredentials
            })

        await #expect(throws: QoderUsageError.invalidCredentials) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil))))
        }
    }

    @Test
    func `auto cookie fetch preserves terminal non auth error when fresh import is exhausted`() async {
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, _, _ in
                throw QoderUsageError.networkError("global timed out")
            },
            cookieResolver: { _, allowCached, _ in
                if allowCached {
                    return QoderResolvedCookie(
                        cookieHeader: "sid=stale-cache",
                        sourceLabel: "Chrome Default / qoder.com",
                        isFromCache: true)
                }
                throw QoderUsageError.missingCredentials
            })

        await #expect(throws: QoderUsageError.networkError("global timed out")) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil))))
        }
    }

    @Test
    func `auto cookie fetch preserves terminal non auth error when later candidate also fails`() async {
        let candidates = [
            QoderResolvedCookie(cookieHeader: "sid=global", sourceLabel: "Chrome Default / qoder.com"),
            QoderResolvedCookie(cookieHeader: "sid=china", sourceLabel: "Chrome Default / qoder.com.cn"),
        ]
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, _, _ in
                if cookieHeader == "sid=global" {
                    throw QoderUsageError.networkError("timed out")
                }
                throw QoderUsageError.apiError(503)
            },
            cookieResolver: { _, _, skippedLabels in
                candidates.first { !skippedLabels.contains($0.sourceLabel) }
            })

        await #expect(throws: QoderUsageError.apiError(503)) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil))))
        }
    }

    @Test
    func `auto cookie fetch preserves later non auth error after auth failure`() async {
        let candidates = [
            QoderResolvedCookie(cookieHeader: "sid=global", sourceLabel: "Chrome Default / qoder.com"),
            QoderResolvedCookie(cookieHeader: "sid=china", sourceLabel: "Chrome Default / qoder.com.cn"),
        ]
        let strategy = QoderWebFetchStrategy(
            usageLoader: { cookieHeader, _, _ in
                if cookieHeader == "sid=global" {
                    throw QoderUsageError.invalidCredentials
                }
                throw QoderUsageError.networkError("china timed out")
            },
            cookieResolver: { _, _, skippedLabels in
                candidates.first { !skippedLabels.contains($0.sourceLabel) }
            })

        await #expect(throws: QoderUsageError.networkError("china timed out")) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .auto,
                    manualCookieHeader: nil))))
        }
    }

    @Test
    func `manual plain cookie fetch reports invalid credentials when every candidate is auth failure`() async {
        let strategy = QoderWebFetchStrategy(
            usageLoader: { _, _, _ in
                throw QoderUsageError.invalidCredentials
            })

        await #expect(throws: QoderUsageError.invalidCredentials) {
            try await strategy.fetch(self.makeContext(settings: .make(
                qoder: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "sid=plain-cookie"))))
        }
    }

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
        #expect(store.weeklyPace(provider: .qoder, window: restoredPrimary, now: Date()) == nil)

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
