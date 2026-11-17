import Foundation

public enum QoderProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.spec.makeDescriptor(
        credentials: Self.credentials,
        fetchPlan: Self.fetchPlan())
    public static let spec = PluginProviderSpec(
        id: .qoder,
        displayName: "Qoder",
        sessionLabel: "Credits",
        weeklyLabel: "Add-on credits",
        creditsHint: "Big model credits from the Qoder usage dashboard.",
        debugLogUnavailableMessage: "Qoder debug log not yet implemented",
        usesDetailBackedWindow: true,
        dashboardURL: QoderWebSite.international.dashboardURL.absoluteString,
        color: ProviderColor(hex: 0x10B981),
        confetti: [0x2ADB5C, 0x111113, 0xFFFFFF],
        noDataMessage: "Qoder cost summary is not supported.",
        presentation: ProviderUsagePresentation(
            rateWindowLabeler: { metadata, snapshot, _ in
                ProviderRateWindowLabels(
                    primary: snapshot.primary?.title ?? metadata.sessionLabel,
                    secondary: snapshot.secondary?.title ?? metadata.weeklyLabel,
                    tertiary: metadata.opusLabel ?? "Sonnet",
                    showsTertiary: metadata.supportsOpus)
            },
            extraRateWindowSelector: { snapshot in
                snapshot.extraRateWindows ?? []
            },
            treatsExhaustedSecondaryIconWindowAsMissing: true,
            semanticWindowResolver: { snapshot in
                ProviderSemanticWindows(session: snapshot.primary, weekly: snapshot.secondary)
            },
            menuBarLayoutSecondaryLabel: "Credits",
            automaticSelectionPrioritizesExhaustedWindow: false,
            switcherUsesAutomaticMenuBarWindow: true,
            menuBarWindowResolver: { context in
                guard context.metric == .automatic else { return .unhandled }
                let windows = [context.snapshot.primary, context.snapshot.secondary].compactMap(\.self)
                    + (context.snapshot.extraRateWindows ?? []).filter(\.usageKnown).map(\.window)
                return .resolved(windows.first { $0.remainingPercent > 0 } ?? windows.first)
            },
            menuCard: ProviderMenuCardPresentation(
                showsPrimaryBalanceDescription: true,
                showsSecondaryBalanceDescription: true,
                hidesPrimaryResetWithoutDate: true,
                extraRateWindowUsesResetDescriptionAsDetail: { namedWindow in
                    namedWindow.id == "qoder-add-on" || namedWindow.id == "qoder-org-resource-package"
                }),
            menu: ProviderMenuDescriptorPresentation(
                primaryDescriptionIsDetail: { _ in true },
                secondaryDescriptionMode: .resetOverride)),
        webSource: .init(
            settingsSection: .init(QoderProviderSettingsKey.self, cookieSettings: QoderProviderSettings.self),
            browserCookieOrder: ProviderBrowserCookieDefaults.defaultImportOrder,
            browserSupportExemption: { _, _, settings in
                settings?.qoder?.cookieSource == .manual
            },
            field: .init(
                id: "qoder-cookie",
                title: "",
                subtitle: "",
                placeholder: "Cookie: \u{2026}\n\nor paste a cURL capture from the Qoder usage page",
                action: (id: "qoder-open-usage", title: "Open Qoder Usage", url: "https://qoder.com/account/usage")),
            picker: .init(
                id: "qoder-cookie-source",
                allowsOff: false,
                auto: .localized("Automatic imports browser cookies."),
                manual: .localized("Paste a Cookie header or cURL capture from %@.", argument: "Qoder usage"),
                off: .localized("%@ cookies are disabled.", argument: "Qoder"))))

    private static let credentials = ProviderCredentialAdapter(tokenAccountSupport: TokenAccountSupport(
        title: "Session tokens",
        subtitle: "Store multiple Qoder Cookie headers.",
        placeholder: "Cookie: …",
        injection: .cookieHeader,
        requiresManualCookieSource: true,
        cookieName: nil))

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(
            sourceModes: [.auto, .web],
            pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [QoderPluginFetchStrategy()] }))
    }

    public static func dashboardURL(
        settings: ProviderSettingsSnapshot.QoderProviderSettings?,
        sourceLabel: String?) -> URL
    {
        guard settings?.cookieSource == .manual else {
            return self.dashboardURL(forSourceLabel: sourceLabel)
        }
        return QoderWebSite.allCases.first { $0.webOrigin == settings?.manualCookieOrigin }?.dashboardURL
            ?? QoderWebSite.international.dashboardURL
    }

    public static func dashboardURL(forSourceLabel sourceLabel: String?) -> URL {
        guard let sourceLabel, !sourceLabel.isEmpty else {
            return QoderWebSite.international.dashboardURL
        }
        return QoderCookieRouting.site(for: sourceLabel).dashboardURL
    }
}

struct QoderPluginFetchStrategy: ProviderFetchStrategy {
    let id = "qoder.js"
    let kind: ProviderFetchKind = .web
    private let script: ScriptFetchStrategy

    init(transport: any ProviderHTTPTransport = ProviderHTTPClient.shared) {
        self.script = ScriptFetchStrategy(
            id: "qoder.js",
            provider: .qoder,
            bundledPlugin: "qoder",
            kind: .web,
            transport: transport,
            resolveValues: { context in
                guard context.settings?.qoder?.cookieSource != .off else { return nil }
                let deadline = Date()
                    .addingTimeInterval(ProviderPluginRuntime.defaultTimeout - 1)
                    .timeIntervalSince1970 * 1000
                return .init(settings: [
                    "REQUEST_TIMEOUT": String(min(30, max(1, context.webTimeout))),
                    "REQUEST_DEADLINE_MILLIS": String(deadline),
                ])
            }, isEnabled: { _ in true })
    }

    func isAvailable(_ context: ProviderFetchContext) async -> Bool { await self.script.isAvailable(context) }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let result = try await self.script.fetch(context)
        let source = result.usage.identity?.loginMethod ?? "web"
        let usage = result.usage.withIdentity(ProviderIdentitySnapshot(
            providerID: .qoder,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil))
        return self.makeResult(usage: usage, sourceLabel: source)
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
}
