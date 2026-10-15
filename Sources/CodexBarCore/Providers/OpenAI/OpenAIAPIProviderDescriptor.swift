import Foundation

public enum OpenAIAPIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey,
        apiKeyDebugLabel: OpenAIAPISettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [
            .workspaceID(OpenAIAPISettingsReader.projectIDEnvironmentKey),
            .init(key: "OPENAI_LIVE_MINUTES", value: { $0.pluginSettings?["OPENAI_LIVE_MINUTES"] }),
        ],
        resolve: OpenAIAPISettingsReader.apiKey,
        tokenAccountSupport: TokenAccountSupport(
            title: "API keys",
            subtitle: "Store multiple OpenAI API keys.",
            placeholder: "sk-admin-...",
            injection: .environment(key: OpenAIAPISettingsReader.adminAPIKeyEnvironmentKey),
            requiresManualCookieSource: false,
            cookieName: nil,
            environmentKeysToScrub: [OpenAIAPISettingsReader.projectIDEnvironmentKey]))

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .openai,
            credentials: self.credentials,
            pluginResultPolicy: ProviderPluginResultPolicy(cardMapper: mapPluginCard),
            config: ProviderConfigCapabilities(workspaceIDValidationOrder: 1),
            metadata: ProviderMetadata(
                id: .openai,
                displayName: "OpenAI",
                sessionLabel: "Spend",
                weeklyLabel: "Requests",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show OpenAI usage",
                cliName: "openai",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://platform.openai.com/usage",
                statusPageURL: "https://status.openai.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .openai),
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor(red: 0.06, green: 0.51, blue: 0.43),
                confettiPalette: [
                    ProviderColor(hex: 0x000000),
                    ProviderColor(hex: 0x808080),
                    ProviderColor(hex: 0xFFFFFF),
                ],
                widgetColor: ProviderColor(red: 15 / 255, green: 130 / 255, blue: 110 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "OpenAI usage needs an Admin API key for organization usage." },
                showsCostMenuSection: false,
                // The KPI grid already shows requests; the source label sits in the card header.
                showsRequestHistory: false),
            presentation: ProviderUsagePresentation(
                costPresenter: { snapshot in
                    let style: ProviderCostMenuCardStyle = (snapshot.providerCost?.limit ?? 1) <= 0
                        ? .apiSpend
                        : .generic
                    return ProviderCostPresentation(menuCardStyle: style)
                },
                menuCard: ProviderMenuCardPresentation(
                    usageNotesResolver: { context in
                        context.snapshot?.openAIAPIUsage.map(ProviderUsageNotesResolution.openAIAPI) ?? .unhandled
                    },
                    costVisibilityResolver: { $0.snapshot?.openAIAPIUsage == nil },
                    usesProviderCostHistoryAsPrimaryDashboard: true,
                    primaryCostHistoryResolver: { snapshot, tokenSnapshot in
                        if let projected = snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot() {
                            return projected
                        }
                        return snapshot == nil ? tokenSnapshot : nil
                    }),
                optionalDetails: ProviderOptionalDetailsPresentation(
                    costSummaryTitles: ["Usage summary"])),
            fetchPlan: self.fetchPlan(),
            cli: ProviderCLIConfig(
                name: "openai",
                aliases: ["openai-api"],
                versionDetector: nil))
    }

    private static func fetchPlan() -> ProviderFetchPlan {
        ProviderFetchPlan(sourceModes: [.auto, .api], pipeline: ProviderFetchPipeline(resolveStrategies: { _ in
            [Self.scriptStrategy()]
        }))
    }

    static func scriptStrategy(transport: any ProviderHTTPTransport = ProviderHTTPClient
        .shared) -> ScriptFetchStrategy
    {
        ScriptFetchStrategy(
            id: "openai.js",
            provider: .openai,
            bundledPlugin: "openai",
            secretKey: OpenAIAPISettingsReader.apiKeyEnvironmentKey,
            transport: transport,
            resolveValues: { context in
                guard let credential = OpenAIAPIUsageCredential(environment: context.env) else { return nil }
                var settings = [
                    "OPENAI_LIVE_MINUTES": context.env["OPENAI_LIVE_MINUTES"] == "0" ? "0" : "60",
                    "OPENAI_HISTORY_DAYS": String(context.costUsageHistoryDays),
                    "OPENAI_ALLOW_BALANCE_FALLBACK": credential.allowsLegacyBalanceFallback ? "1" : "0",
                ]
                settings[OpenAIAPISettingsReader.projectIDEnvironmentKey] = credential.projectID
                return .init(
                    settings: settings,
                    secrets: [OpenAIAPISettingsReader.apiKeyEnvironmentKey: credential.apiKey])
            }, isEnabled: { _ in true })
    }
}

struct OpenAIAPIUsageCredential: Equatable {
    let apiKey: String
    let projectID: String?
    let usesAdminKey: Bool

    init?(environment: [String: String]) {
        if let adminKey = OpenAIAPISettingsReader.adminAPIKey(environment: environment) {
            self.apiKey = adminKey
            self.usesAdminKey = true
        } else if let apiKey = OpenAIAPISettingsReader.apiKey(environment: environment) {
            self.apiKey = apiKey
            self.usesAdminKey = false
        } else {
            return nil
        }
        self.projectID = OpenAIAPISettingsReader.projectID(environment: environment)
    }

    var allowsLegacyBalanceFallback: Bool {
        self.projectID == nil || !self.usesAdminKey
    }
}

extension OpenAIAPIProviderDescriptor {
    static func mapPluginCard(
        _ card: any ProviderPluginValue,
        usage: UsageSnapshot,
        now: Date) throws -> UsageSnapshot
    {
        typealias Mapper = ProviderPluginSnapshotMapper
        try Mapper.object(card, allowed: ["openAIAPIUsage"], path: "card")
        guard let payload = card.property("openAIAPIUsage") else {
            throw ProviderPluginError.invalidSnapshot("card.openAIAPIUsage is required")
        }
        try Mapper.object(payload, allowed: ["daily", "historyDays", "projectID", "live"], path: "card.openAIAPIUsage")
        let historyDays = try Self.cardInteger(payload, "historyDays", maximum: 365)
        guard historyDays > 0 else { throw ProviderPluginError.invalidSnapshot("historyDays must be positive") }
        let project = payload.property("projectID")
        let projectID = try project.flatMap { $0.isUndefined || $0.isNull ? nil : try Mapper.resultString(
            $0,
            path: "projectID") }
        var remainingEntries = 10000
        let daily = try Self.cardArray(payload, "daily", maximum: 366).map { day in
            try Mapper.object(
                day,
                allowed: [
                    "startTime", "endTime", "costUSD", "requests", "inputTokens", "cachedInputTokens",
                    "outputTokens",
                    "totalTokens", "lineItems", "models",
                ],
                path: "daily bucket")
            let start = try Self.cardNumber(day, "startTime")
            let end = try Self.cardNumber(day, "endTime")
            guard start >= 0, end > start, end <= 253_402_300_799 else {
                throw ProviderPluginError.invalidSnapshot("invalid card bucket interval")
            }
            let lines = try Self.cardArray(day, "lineItems", maximum: remainingEntries)
            remainingEntries -= lines.count
            let models = try Self.cardArray(day, "models", maximum: remainingEntries)
            remainingEntries -= models.count
            let startDate = Date(timeIntervalSince1970: start)
            return try OpenAIAPIUsageSnapshot.DailyBucket(
                day: ISO8601DateFormatter().string(from: startDate).prefix(10).description,
                startTime: startDate,
                endTime: Date(timeIntervalSince1970: end),
                costUSD: Self.cardNumber(day, "costUSD"),
                requests: Self.cardInteger(day, "requests"),
                inputTokens: Self.cardInteger(day, "inputTokens"),
                cachedInputTokens: Self.cardInteger(day, "cachedInputTokens"),
                outputTokens: Self.cardInteger(day, "outputTokens"),
                totalTokens: Self.cardInteger(day, "totalTokens"),
                lineItems: lines.map { item in
                    try Mapper.object(item, allowed: ["name", "costUSD"], path: "line item")
                    return try .init(name: Self.cardName(item), costUSD: Self.cardNumber(item, "costUSD"))
                },
                models: models.map { model in
                    try Mapper.object(
                        model,
                        allowed: [
                            "name", "requests", "inputTokens", "cachedInputTokens", "outputTokens",
                            "totalTokens",
                        ],
                        path: "model")
                    return try .init(
                        name: Self.cardName(model),
                        requests: Self.cardInteger(model, "requests"),
                        inputTokens: Self.cardInteger(model, "inputTokens"),
                        cachedInputTokens: Self.cardInteger(model, "cachedInputTokens"),
                        outputTokens: Self.cardInteger(model, "outputTokens"),
                        totalTokens: Self.cardInteger(model, "totalTokens"))
                })
        }
        let history = OpenAIAPIUsageSnapshot(
            daily: daily,
            updatedAt: now,
            historyDays: historyDays,
            projectID: projectID)
        return UsageSnapshot(
            primary: usage.primary,
            secondary: usage.secondary,
            tertiary: usage.tertiary,
            extraRateWindows: usage.extraRateWindows,
            providerCost: usage.providerCost,
            costUsage: usage.costUsage,
            details: usage.details,
            throughput: payload.property("live").flatMap {
                try? Self.mapLiveUsage($0, projectID: projectID, maximumEntries: remainingEntries).throughput
            },
            openAIAPIUsage: history,
            subscriptionExpiresAt: usage.subscriptionExpiresAt,
            subscriptionRenewsAt: usage.subscriptionRenewsAt,
            updatedAt: now,
            identity: usage.identity,
            dataConfidence: usage.dataConfidence)
    }

    static func cardArray(
        _ object: any ProviderPluginValue, _ key: String, maximum: Int) throws -> [any ProviderPluginValue]
    {
        guard let value = object.property(key), value.isArray,
              let length = value.property("length"), length.isNumber
        else { throw ProviderPluginError.invalidSnapshot("card.\(key) must be a bounded array") }
        let count = length.doubleValue()
        guard count.isFinite, count >= 0, count.rounded() == count, count <= Double(maximum) else {
            throw ProviderPluginError.invalidSnapshot("card.\(key) must be a bounded array")
        }
        return try (0..<Int(count)).map { index in
            guard let element = value.element(at: index) else {
                throw ProviderPluginError.invalidSnapshot("card.\(key) contains a missing value")
            }
            return element
        }
    }

    static func cardNumber(_ object: any ProviderPluginValue, _ key: String) throws -> Double {
        guard let value = object.property(key), value.isNumber,
              value.doubleValue().isFinite, abs(value.doubleValue()) <= 9_007_199_254_740_991
        else { throw ProviderPluginError.invalidSnapshot("card.\(key) must be a finite safe number") }
        return value.doubleValue()
    }

    static func cardInteger(
        _ object: any ProviderPluginValue, _ key: String, maximum: Int = 900_719_925_474) throws -> Int
    {
        // The aggregate of every bounded card row must also fit in a JavaScript-safe integer.
        let number = try Self.cardNumber(object, key)
        guard number >= 0, number.rounded() == number, number <= Double(maximum) else {
            throw ProviderPluginError.invalidSnapshot("card.\(key) must be a bounded nonnegative integer")
        }
        return Int(number)
    }

    static func cardName(_ object: any ProviderPluginValue) throws -> String {
        guard let name = object.property("name")
        else { throw ProviderPluginError.invalidSnapshot("card.name is required") }
        return try ProviderPluginSnapshotMapper.resultString(name, path: "card.name")
    }
}
