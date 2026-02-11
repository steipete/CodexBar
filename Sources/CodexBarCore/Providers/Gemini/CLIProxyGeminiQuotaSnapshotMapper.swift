import Foundation

public enum CLIProxyGeminiQuotaSnapshotMapper {
    public static func usageSnapshot(
        from response: CLIProxyGeminiQuotaResponse,
        auth: CodexCLIProxyResolvedAuth,
        provider: UsageProvider) -> UsageSnapshot
    {
        let modelBuckets = self.reduceByModel(response.buckets)
        let proBucket = self.lowestBucket(matching: "pro", from: modelBuckets)
        let flashBucket = self.lowestBucket(matching: "flash", from: modelBuckets)
        let fallbackBucket = modelBuckets.min(by: { $0.remainingFraction < $1.remainingFraction })

        let primary = self.makeWindow(proBucket ?? fallbackBucket)
            ?? RateWindow(usedPercent: 0, windowMinutes: 1440, resetsAt: nil, resetDescription: nil)
        let secondary = self.makeWindow(flashBucket)

        let normalizedEmail = auth.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: normalizedEmail?.isEmpty == true ? nil : normalizedEmail,
            accountOrganization: nil,
            loginMethod: nil)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
            .scoped(to: provider)
    }

    private static func reduceByModel(_ buckets: [CLIProxyGeminiQuotaBucket]) -> [CLIProxyGeminiQuotaBucket] {
        var byModel: [String: CLIProxyGeminiQuotaBucket] = [:]
        for bucket in buckets {
            guard !bucket.modelID.isEmpty else { continue }
            if let existing = byModel[bucket.modelID], existing.remainingFraction <= bucket.remainingFraction {
                continue
            }
            byModel[bucket.modelID] = bucket
        }
        return byModel.values.sorted { $0.modelID < $1.modelID }
    }

    private static func lowestBucket(
        matching token: String,
        from buckets: [CLIProxyGeminiQuotaBucket]) -> CLIProxyGeminiQuotaBucket?
    {
        buckets
            .filter { $0.modelID.localizedCaseInsensitiveContains(token) }
            .min(by: { $0.remainingFraction < $1.remainingFraction })
    }

    private static func makeWindow(_ bucket: CLIProxyGeminiQuotaBucket?) -> RateWindow? {
        guard let bucket else { return nil }
        let usedPercent = max(0, min(100, (1 - bucket.remainingFraction) * 100))
        let resetDescription = bucket.resetTime.map { UsageFormatter.resetDescription(from: $0) }
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 1440,
            resetsAt: bucket.resetTime,
            resetDescription: resetDescription)
    }
}
