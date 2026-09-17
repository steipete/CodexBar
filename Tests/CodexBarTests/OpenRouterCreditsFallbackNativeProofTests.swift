import AppKit
import SwiftUI
import XCTest
@testable import CodexBar
@testable import CodexBarCore

@MainActor
final class OpenRouterCreditsFallbackNativeProofTests: XCTestCase {
    func test_settingsMetricsKeepAPIKeySpendWhenCreditsReturns403() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CODEXBAR_OPENROUTER_CREDITS_FALLBACK_PROOF_DIR"] else {
            throw XCTSkip("Set CODEXBAR_OPENROUTER_CREDITS_FALLBACK_PROOF_DIR for synthetic native Settings-view proof")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        guard SettingsStore.isRunningTests,
              environment["CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS"] == "1",
              environment[CodexCredentialFileAccess.isolationEnvironmentKey] == "1",
              environment["CODEXBAR_TEST_SESSION_FILE_ISOLATION"] == "1",
              environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1",
              Self.isStrictDescendant(
                  URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                  of: output.deletingLastPathComponent())
        else { return XCTFail("Use a contained home and credential/session isolation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let pluginResult = try await Self.pluginSnapshot(environment: environment, diagnosticsDirectory: output)
        let snapshot = pluginResult.snapshot
        let model = try Self.model(snapshot)
        let settings = testSettingsStore(
            suiteName: "OpenRouterCreditsFallbackNativeProofTests",
            userDefaults: InMemoryUserDefaults(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.statusChecksEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store._setSnapshotForTesting(snapshot, provider: .openrouter)
        let contentState = ProviderMetricsInlineView.ContentState(model: model, infoRows: [])
        let identity = snapshot.identity?.loginMethod
        let balance = try self.row("Balance", in: model)
        let todaySpend = try self.row("Today", in: model).value
        let weekSpend = try self.row("This week", in: model).value
        let monthSpend = try self.row("This month", in: model).value
        XCTAssertFalse(contentState.showsPlaceholder)
        XCTAssertNil(identity)
        XCTAssertNil(model.planText)
        XCTAssertNil(ProviderDetailView<EmptyView>.planRow(provider: .openrouter, planText: model.planText))
        XCTAssertEqual(balance.value, "Unavailable right now")
        XCTAssertEqual(balance.secondaryValue, "Request returned HTTP 403")
        XCTAssertEqual(todaySpend, "$1.25")
        XCTAssertEqual(weekSpend, "$7.50")
        XCTAssertEqual(monthSpend, "$18.75")

        let app = NSApplication.shared
        guard app.delegate == nil else { return XCTFail("Use a standalone test host") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 900),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "CodexBar — Synthetic OpenRouter Settings"
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            _ = app.setActivationPolicy(previousPolicy)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate()
            }
        }

        _ = app.setActivationPolicy(.regular)
        app.finishLaunching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView:
                ProviderDetailView(
                    provider: .openrouter,
                    store: store,
                    isEnabled: .constant(true),
                    subtitle: "Synthetic plugin response · Credits request returned HTTP 403",
                    model: model,
                    openAIWebDiagnostic: nil,
                    settingsPickers: [],
                    settingsToggles: [],
                    settingsFields: [],
                    settingsTokenAccounts: nil,
                    errorDisplay: nil,
                    isErrorExpanded: .constant(false),
                    onCopyError: { _ in },
                    onRefresh: {},
                    supplementarySettingsContent: { EmptyView() })
                    .frame(width: 680, height: 900)
                    .background(appearance == .aqua ? Color.white : Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: "en"))
                    .preferredColorScheme(appearance == .aqua ? .light : .dark))
            try await Task.sleep(for: .milliseconds(300))
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("openrouter-credits-403-\(appearance.rawValue).png"))
        }
        try JSONSerialization.data(withJSONObject: [
            "creditsStatus": 403,
            "transport": pluginResult.transport,
            "identity": identity ?? "",
            "planRow": ProviderDetailView<EmptyView>.planRow(
                provider: .openrouter,
                planText: model.planText)?.value ?? "",
            "shownRows": model.providerDetails.flatMap(\.rows).map(\.label),
            "todaySpend": todaySpend,
            "weekSpend": weekSpend,
            "monthSpend": monthSpend,
        ], options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }

    func test_proofHomeContainmentResolvesAliasesAndRejectsSiblings() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("OpenRouterProofContainment-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        let home = actual.appendingPathComponent("home", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: actual)

        XCTAssertTrue(Self.isStrictDescendant(home, of: alias))
        XCTAssertTrue(Self.isStrictDescendant(alias.appendingPathComponent("home"), of: actual))
        XCTAssertFalse(Self.isStrictDescendant(actual, of: alias))
        XCTAssertFalse(Self.isStrictDescendant(root.appendingPathComponent("actual-other/home"), of: actual))
        XCTAssertFalse(Self.isStrictDescendant(root, of: actual))
    }

    private static func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parentComponents = parent.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return childComponents.count > parentComponents.count && childComponents.starts(with: parentComponents)
    }

    private static let syntheticAPIKey = "fixture-key"

    private static func pluginSnapshot(environment: [String: String], diagnosticsDirectory: URL) async throws
    -> (snapshot: UsageSnapshot, transport: String) {
        if let loopback = try OpenRouterLoopbackProofConfiguration(environment: environment) {
            let transport = try OpenRouterPinnedLoopbackTransport(
                certificateDER: Data(contentsOf: loopback.certificateURL),
                port: loopback.port)
            do {
                let snapshot = try await ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)
                    .fetchUsage(
                        settings: [OpenRouterSettingsReader.apiURLEnvironmentKey: loopback.apiURL.absoluteString],
                        secrets: [OpenRouterSettingsReader.envKey: Self.syntheticAPIKey])
                try transport.writeDiagnostics(to: diagnosticsDirectory)
                return (snapshot, "loopback-pinned-tls")
            } catch {
                try? transport.writeDiagnostics(to: diagnosticsDirectory)
                throw error
            }
        }
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let statusCode: Int
            let body: String
            switch url.path {
            case "/api/v1/credits":
                statusCode = 403
                body = #"{"error":{"message":"Management key required"}}"#
            case "/api/v1/key":
                statusCode = 200
                body = #"{"data":{"limit":null,"usage_daily":1.25,"usage_weekly":7.5,"usage_monthly":18.75}}"#
            default:
                throw URLError(.unsupportedURL)
            }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])
            else { throw URLError(.cannotParseResponse) }
            return (Data(body.utf8), response)
        }
        let snapshot = try await ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)
            .fetchUsage(secrets: [OpenRouterSettingsReader.envKey: Self.syntheticAPIKey])
        return (snapshot, "synthetic-stub")
    }

    private static func model(_ snapshot: UsageSnapshot) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .openrouter,
            metadata: XCTUnwrap(ProviderDefaults.metadata[.openrouter]),
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
            hidePersonalInfo: true,
            usesLiveSubtitle: false,
            preferredCurrencyCode: "USD",
            now: Date(timeIntervalSince1970: 1_787_079_600)))
    }

    private func row(_ label: String, in model: UsageMenuCardView.Model) throws -> ProviderDetailSection.Row {
        try XCTUnwrap(model.providerDetails.flatMap(\.rows).first { $0.label == label })
    }
}

/// `CODEXBAR_OPENROUTER_PROOF_TLS_CERT` must point to the fixture's DER-encoded certificate.
private struct OpenRouterLoopbackProofConfiguration {
    let certificateURL: URL
    let port: Int

    var apiURL: URL {
        URL(string: "https://127.0.0.1:\(self.port)/api/v1")!
    }

    init?(environment: [String: String]) throws {
        let certificatePath = environment["CODEXBAR_OPENROUTER_PROOF_TLS_CERT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPort = environment["CODEXBAR_OPENROUTER_PROOF_PORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard certificatePath?.isEmpty == false || rawPort?.isEmpty == false else { return nil }
        guard let certificatePath, !certificatePath.isEmpty,
              let rawPort, let port = Int(rawPort), (1...65535).contains(port)
        else { throw URLError(.badURL) }
        self.certificateURL = URL(fileURLWithPath: certificatePath)
        self.port = port
    }
}
