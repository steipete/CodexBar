import Foundation

public enum VertexAIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    public static let estimateHintKey = "vertexai_cost_estimate_hint"
    public static let cloudEstimateHintKey = "vertexai_cloud_cost_estimate_hint"
    public static let estimateHintText =
        "Estimated from Cloud Monitoring and Claude-on-Vertex logs · may differ from your GCP bill"
    public static let cloudEstimateHintText =
        "Estimated from Cloud Monitoring token_count × public API rates · excludes dedicated throughput"

    static func estimateHintKey(forHistoryLabel historyLabel: String?) -> String? {
        guard let historyLabel else { return nil }
        if historyLabel.hasSuffix("(Cloud est.)") {
            return Self.cloudEstimateHintKey
        }
        if historyLabel.hasSuffix("(Cloud + Local est.)") {
            return Self.estimateHintKey
        }
        return nil
    }

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .vertexai,
            settingsSection: .init(VertexAIProviderSettingsKey.self, credentialSettings: { context in
                context.config?.resolvedVertexAISettings ?? VertexAIProviderSettings()
            }),
            metadata: ProviderMetadata(
                id: .vertexai,
                displayName: "Vertex AI",
                shortDisplayName: "Vertex",
                sessionLabel: "Requests",
                weeklyLabel: "Tokens",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Vertex AI usage",
                cliName: "vertexai",
                defaultEnabled: false,
                widgetSelectable: true,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "Vertex AI debug log not yet implemented",
                dashboardURL: "https://console.cloud.google.com/vertex-ai",
                statusPageURL: nil,
                statusLinkURL: "https://status.cloud.google.com"),
            branding: ProviderBranding(
                iconStyle: .init(provider: .vertexai),
                iconResourceName: "ProviderIcon-vertexai",
                color: ProviderColor(red: 66 / 255, green: 133 / 255, blue: 244 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x4285F4),
                    ProviderColor(hex: 0xEA4335),
                    ProviderColor(hex: 0xFBBC04),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Vertex AI cost data found in Claude logs. Ensure entries include Vertex metadata."
                },
                menuHintLines: [.localized("cost_estimate_hint")],
                menuHintLinesResolver: { snapshot in
                    Self.estimateHintKey(forHistoryLabel: snapshot.historyLabel).map { [.localized($0)] }
                },
                supportsTokenSnapshot: true,
                settingsStatusOrder: 4,
                showsHintInProviderDetails: true,
                chartEstimateDisclaimer: .localized(self.estimateHintKey),
                chartEstimateDisclaimerResolver: { historyLabel in
                    Self.estimateHintKey(forHistoryLabel: historyLabel).map(ProviderTokenCostHint.localized)
                }),
            history: .unavailable,
            presentation: ProviderUsagePresentation(
                rateWindowLabeler: { metadata, snapshot, _ in
                    ProviderRateWindowLabels(
                        primary: snapshot.primary?.title ?? metadata.sessionLabel,
                        secondary: snapshot.secondary?.title ?? metadata.weeklyLabel,
                        tertiary: metadata.opusLabel ?? "Sonnet",
                        showsTertiary: metadata.supportsOpus)
                },
                menuCard: ProviderMenuCardPresentation(
                    supportsInlineTokenCostDashboard: true,
                    primaryDescriptionPlacement: .detail,
                    showsSecondaryBalanceDescription: true,
                    hidesPrimaryResetWithoutDate: true)),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .oauth],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [VertexAIOAuthFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "vertexai",
                versionDetector: nil,
                supportsCostCommand: true))
    }
}

struct VertexAIOAuthFetchStrategy: ProviderFetchStrategy {
    let id: String = "vertexai.oauth"
    let kind: ProviderFetchKind = .oauth

    #if DEBUG
    @TaskLocal static var transportForTesting: (any ProviderHTTPTransport)?
    #endif

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        VertexAIOAuthCredentialsStore.hasCredentials(environment: context.env)
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let settings = context.settings?.vertexai ?? VertexAIProviderSettings()
        #if DEBUG
        let transport = Self.transportForTesting ?? ProviderHTTPClient.shared
        #else
        let transport = ProviderHTTPClient.shared
        #endif

        let credentials = try await VertexAIOAuthCredentialsStore.resolveValidCredentials(
            environment: context.env,
            projectIDOverride: settings.projectIDOverride,
            refreshTransport: transport,
            persistRefreshed: true)

        if settings.telemetryCostSource == .localClaudeLogsOnly {
            return self.makeResult(
                usage: Self.mapUsage(nil, credentials: credentials, settings: settings),
                sourceLabel: "oauth")
        }

        // Fetch quota usage and serving telemetry from Cloud Monitoring. If no data is found,
        // return an identity-preserving snapshot so local token costs can still display.
        let usage: VertexAIUsageResponse?
        do {
            usage = try await VertexAIUsageFetcher.fetchUsageSnapshot(
                accessToken: credentials.accessToken,
                projectId: credentials.projectId,
                options: VertexAIQueryOptions(
                    locationFilter: settings.regionFilter,
                    baseModelFilter: settings.modelFilter,
                    includeOnlineServing: true,
                    servingWindowDays: 1),
                transport: transport)
        } catch VertexAIFetchError.noData {
            usage = nil
        }

        return self.makeResult(
            usage: Self.mapUsage(usage, credentials: credentials, settings: settings),
            sourceLabel: "oauth")
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if error is VertexAIOAuthCredentialsError {
            return true
        }
        if let fetchError = error as? VertexAIFetchError {
            switch fetchError {
            case .unauthorized, .forbidden:
                return true
            default:
                return false
            }
        }
        return false
    }

    static func mapUsage(
        _ response: VertexAIUsageResponse?,
        credentials: VertexAIOAuthCredentials,
        settings: VertexAIProviderSettings = VertexAIProviderSettings()) -> UsageSnapshot
    {
        let identity = ProviderIdentitySnapshot(
            providerID: .vertexai,
            accountEmail: credentials.email,
            accountOrganization: credentials.projectId,
            loginMethod: "gcloud")

        guard let response else {
            let details = Self.activeFilterSection(settings: settings, projectId: credentials.projectId)
                .map { [$0] } ?? []
            return UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: nil,
                details: details,
                updatedAt: Date(),
                identity: identity)
        }

        let (primaryBucket, secondaryBucket) = Self.selectBuckets(
            from: response,
            metric: settings.primaryBarMetric)
        let primaryWindow = primaryBucket.map(Self.rateWindow(from:))
        let secondaryWindow = secondaryBucket.map(Self.rateWindow(from:))
        let details = Self.detailSections(
            from: response,
            settings: settings,
            projectId: credentials.projectId)

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: secondaryWindow,
            providerCost: nil,
            details: details,
            updatedAt: Date(),
            identity: identity)
    }

    private static func selectBuckets(
        from response: VertexAIUsageResponse,
        metric: VertexAIPrimaryBarMetric) -> (primary: VertexAIQuotaBucketUsage?, secondary: VertexAIQuotaBucketUsage?)
    {
        let rate = response.highestRateQuota
        let allocation = response.highestAllocationQuota
        switch metric {
        case .auto:
            if let rate, let allocation {
                if rate.usedPercent >= allocation.usedPercent {
                    return (rate, allocation)
                }
                return (allocation, rate)
            }
            return (rate ?? allocation, nil)
        case .rateQuota:
            return (rate ?? allocation, rate != nil ? allocation : nil)
        case .allocationQuota:
            return (allocation ?? rate, allocation != nil ? rate : nil)
        }
    }

    private static func rateWindow(from bucket: VertexAIQuotaBucketUsage) -> RateWindow {
        let scopeParts = [bucket.location, bucket.baseModel.map(VertexAIUsageFetcher.normalizedModelName)]
            .compactMap(\.self)
        let scope = scopeParts.joined(separator: " · ")
        let usageText = Self.formatCompactNumber(bucket.usage)
        let limitText = Self.formatCompactNumber(bucket.limit)

        let title: String
        let windowMinutes: Int?
        let cadenceLabel: String
        switch bucket.cadence {
        case .perMinute:
            title = bucket.isTokenQuota ? "Rate quota (TPM)" : "Rate quota (RPM)"
            windowMinutes = 1
            cadenceLabel = "peak/min"
        case .perDay:
            title = bucket.isTokenQuota ? "Daily quota (TPD)" : "Daily quota (RPD)"
            windowMinutes = 1440
            cadenceLabel = "today"
        case .allocation:
            title = "Allocation quota"
            windowMinutes = nil
            cadenceLabel = "allocated"
        }

        let description = scope.isEmpty
            ? "\(usageText)/\(limitText) \(cadenceLabel)"
            : "\(usageText)/\(limitText) \(cadenceLabel) · \(scope)"

        return RateWindow(
            usedPercent: bucket.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: bucket.resetsAt,
            resetDescription: description,
            quotaLimit: bucket.limit,
            quotaUnit: bucket.unit,
            title: title)
    }

    private static func detailSections(
        from response: VertexAIUsageResponse,
        settings: VertexAIProviderSettings,
        projectId: String?) -> [ProviderDetailSection]
    {
        var sections: [ProviderDetailSection] = []

        let combinedQuotas = (response.rateQuotas + response.allocationQuotas)
            .sorted { lhs, rhs in
                let lhsPercent = lhs.usedPercent.isFinite ? lhs.usedPercent : -Double.infinity
                let rhsPercent = rhs.usedPercent.isFinite ? rhs.usedPercent : -Double.infinity
                if lhsPercent != rhsPercent {
                    return lhsPercent > rhsPercent
                }
                if lhs.exceededCount != rhs.exceededCount {
                    return lhs.exceededCount > rhs.exceededCount
                }
                if lhs.quotaMetric != rhs.quotaMetric {
                    return lhs.quotaMetric < rhs.quotaMetric
                }
                return lhs.limitName < rhs.limitName
            }
        if !combinedQuotas.isEmpty {
            let rows = combinedQuotas.prefix(8).map { bucket in
                let label = bucket.displayName ?? Self.shortQuotaMetricLabel(bucket.quotaMetric)
                let percentText = "\(max(0, Self.clampedRoundedInt(bucket.usedPercent)))%"
                let ratioText = "\(Self.formatCompactNumber(bucket.usage))/\(Self.formatCompactNumber(bucket.limit))"
                let secondaryParts: [String?] = [
                    bucket.location,
                    bucket.baseModel.map(VertexAIUsageFetcher.normalizedModelName),
                    bucket.exceededCount > 0 ? "Exceeded \(bucket.exceededCount)x" : nil,
                ]
                let secondary = secondaryParts.compactMap(\.self).joined(separator: " · ")
                let severity: ProviderDetailSection.Row.Severity = if bucket.exceededCount > 0 || bucket
                    .usedPercent >= 95
                {
                    .critical
                } else if bucket.usedPercent >= 80 {
                    .warning
                } else {
                    .normal
                }
                let progress = (bucket.limit > 0 && bucket.usage.isFinite && bucket.limit.isFinite)
                    ? ProviderDetailSection.Row.Progress.makeProgress(used: bucket.usage, total: bucket.limit)
                    : nil
                return ProviderDetailSection.makeRow(
                    label: label,
                    value: "\(percentText) · \(ratioText)",
                    secondaryValue: secondary.isEmpty ? nil : secondary,
                    progress: progress,
                    severity: severity,
                    usageValue: bucket.usage.isFinite ? bucket.usage : nil)
            }
            sections.append(ProviderDetailSection.makeSection(title: "Quota breakdown", rows: rows))
        }

        if let serving = response.onlineServingSummary {
            var rows: [ProviderDetailSection.Row] = []
            let splitText: String? = if serving.dedicatedInvocations > 0 {
                "Shared \(UsageFormatter.tokenCountString(serving.sharedInvocations)) · " +
                    "Dedicated \(UsageFormatter.tokenCountString(serving.dedicatedInvocations))"
            } else if serving.sharedInvocations > 0 {
                "Shared pay-as-you-go"
            } else {
                nil
            }
            rows.append(ProviderDetailSection.makeRow(
                label: "Invocations",
                value: UsageFormatter.tokenCountString(serving.totalInvocations),
                secondaryValue: splitText))
            rows.append(ProviderDetailSection.makeRow(
                label: "Total tokens",
                value: UsageFormatter.tokenCountString(serving.totalTokens),
                secondaryValue: "In \(UsageFormatter.tokenCountString(serving.inputTokens)) · " +
                    "Out \(UsageFormatter.tokenCountString(serving.outputTokens))"))
            if let estimatedCostUSD = serving.estimatedCostUSD {
                let costNote = serving.hasUnpricedTokens
                    ? "Partial estimate · excludes dedicated/unpriced"
                    : "API-rate estimate"
                rows.append(ProviderDetailSection.makeRow(
                    label: "Est. cost",
                    value: UsageFormatter.usdString(estimatedCostUSD),
                    secondaryValue: costNote))
            }

            for model in serving.models.prefix(8) {
                let modelName = VertexAIUsageFetcher.normalizedModelName(model.modelUserID)
                let reqText = UsageFormatter.tokenCountString(model.invocations)
                let tokensText = "\(UsageFormatter.tokenCountString(model.totalTokens)) tokens"
                let value = model.estimatedCostUSD.map {
                    "\(UsageFormatter.usdString($0)) · \(tokensText)"
                } ?? tokensText
                let inOutText = "In \(UsageFormatter.tokenCountString(model.inputTokens)) · " +
                    "Out \(UsageFormatter.tokenCountString(model.outputTokens))"
                rows.append(ProviderDetailSection.makeRow(
                    label: modelName,
                    value: value,
                    secondaryValue: "\(reqText) req · \(inOutText) · \(model.location) · \(model.requestType)"))
            }
            sections.append(ProviderDetailSection.makeSection(title: "Online serving (24h)", rows: rows))
        }

        if let filterSection = Self.activeFilterSection(settings: settings, projectId: projectId) {
            sections.append(filterSection)
        }

        return Array(sections.prefix(ProviderDetailSection.maximumSectionsPerSnapshot))
    }

    private static func activeFilterSection(
        settings: VertexAIProviderSettings,
        projectId: String?) -> ProviderDetailSection?
    {
        guard settings.projectIDOverride != nil || settings.regionFilter != nil || settings.modelFilter != nil else {
            return nil
        }
        var rows: [ProviderDetailSection.Row] = []
        if let projectOverride = settings.projectIDOverride {
            rows.append(ProviderDetailSection.makeRow(label: "Project", value: projectId ?? projectOverride))
        }
        if let regionFilter = settings.regionFilter {
            rows.append(ProviderDetailSection.makeRow(label: "Region", value: regionFilter))
        }
        if let modelFilter = settings.modelFilter {
            rows.append(ProviderDetailSection.makeRow(label: "Model", value: modelFilter))
        }
        return ProviderDetailSection.makeSection(title: "Active filter", rows: rows)
    }

    private static func shortQuotaMetricLabel(_ metric: String) -> String {
        let tail = metric.split(separator: "/").last.map(String.init) ?? metric
        return tail.replacingOccurrences(of: "_", with: " ")
    }

    private static func clampedRoundedInt(_ value: Double) -> Int {
        guard value.isFinite else {
            if value.isNaN { return 0 }
            return value > 0 ? Int.max : Int.min
        }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    private static func formatCompactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value) >= 1000 {
            return UsageFormatter.tokenCountString(self.clampedRoundedInt(value))
        }
        if value == value.rounded() {
            return String(self.clampedRoundedInt(value))
        }
        return String(format: "%.1f", value)
    }
}
