import Foundation

extension OpenAIAPIProviderDescriptor {
    static func mapLiveUsage(
        _ live: any ProviderPluginValue,
        projectID: String?,
        maximumEntries: Int) throws -> OpenAILiveUsageSnapshot
    {
        typealias Mapper = ProviderPluginSnapshotMapper
        try Mapper.object(
            live,
            allowed: ["windowMinutes", "startTime", "fetchedAt", "buckets"],
            path: "live")
        let window = try Self.cardInteger(
            live,
            "windowMinutes",
            maximum: 60)
        let fetchedAt = try Self.cardInteger(
            live,
            "fetchedAt",
            maximum: 253_402_300_799)
        let start = try Self.cardInteger(
            live,
            "startTime",
            maximum: 253_402_300_799)
        guard window == 60, start == fetchedAt / 60 * 60 - 59 * 60 else {
            throw ProviderPluginError.invalidSnapshot("invalid live interval")
        }
        var remaining = maximumEntries
        let buckets = try Self.cardArray(
            live,
            "buckets",
            maximum: 60).map { bucket in
            try Mapper.object(
                bucket,
                allowed: ["startTime", "models"],
                path: "live bucket")
            let minute = try Self.cardInteger(
                bucket,
                "startTime",
                maximum: fetchedAt)
            guard minute >= start, minute % 60 == 0 else {
                throw ProviderPluginError.invalidSnapshot("invalid live minute")
            }
            let models = try Self.cardArray(
                bucket,
                "models",
                maximum: min(200, remaining))
            remaining -= models.count
            return try OpenAILiveUsageSnapshot.Minute(
                start: Date(timeIntervalSince1970: Double(minute)),
                models: models.map { model in
                    try Mapper.object(
                        model,
                        allowed: [
                            "name", "inputTokens", "cachedInputTokens", "outputTokens", "requests",
                            "batchTokens", "batchRequests",
                        ],
                        path: "live model")
                    return try .init(
                        name: Self.cardName(model),
                        inputTokens: Self.cardInteger(model, "inputTokens"),
                        cachedInputTokens: Self.cardInteger(model, "cachedInputTokens"),
                        outputTokens: Self.cardInteger(model, "outputTokens"),
                        requests: Self.cardInteger(model, "requests"),
                        batchTokens: Self.cardOptionalLiveInteger(model, "batchTokens"),
                        batchRequests: Self.cardOptionalLiveInteger(model, "batchRequests"))
                })
        }
        do {
            return try OpenAILiveUsageBuilder.build(
                buckets: buckets,
                windowMinutes: window,
                fetchedAt: Date(timeIntervalSince1970: Double(fetchedAt)),
                projectID: projectID)
        } catch {
            throw ProviderPluginError.invalidSnapshot("invalid live model totals")
        }
    }

    private static func cardOptionalLiveInteger(_ model: any ProviderPluginValue, _ key: String) throws -> Int {
        guard let value = model.property(key), !value.isUndefined else { return 0 }
        return try Self.cardInteger(model, key)
    }
}
