import Foundation

/// Aggregated stats from local `~/.grok/sessions/**/signals.json` files.
/// Used as a local fallback view when the JSON-RPC billing call is unavailable.
public struct GrokLocalSessionSummary: Sendable {
    public let sessionCount: Int
    public let totalTokens: Int
    public let lastSessionAt: Date?
    public let primaryModel: String?
    public let models: [String]

    public init(
        sessionCount: Int,
        totalTokens: Int,
        lastSessionAt: Date?,
        primaryModel: String?,
        models: [String])
    {
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.lastSessionAt = lastSessionAt
        self.primaryModel = primaryModel
        self.models = models
    }
}

public enum GrokLocalSessionScanner {
    public static let defaultLookbackDays = 30

    /// Walk `~/.grok/sessions/<encoded_cwd>/<session_id>/signals.json` and aggregate stats.
    public static func summarize(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        lookbackDays: Int = defaultLookbackDays,
        now: Date = .init()) -> GrokLocalSessionSummary
    {
        let root = GrokCredentialsStore.grokHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let rootEnum = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else {
            return GrokLocalSessionSummary(
                sessionCount: 0,
                totalTokens: 0,
                lastSessionAt: nil,
                primaryModel: nil,
                models: [])
        }

        let lookbackCutoff = Calendar.current.date(byAdding: .day, value: -lookbackDays, to: now) ?? now
        var sessionCount = 0
        var totalTokens = 0
        var lastSessionAt: Date?
        var modelCounts: [String: Int] = [:]

        while let url = rootEnum.nextObject() as? URL {
            guard url.lastPathComponent == "signals.json" else { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            guard mtime >= lookbackCutoff else { continue }

            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            sessionCount += 1
            let beforeCompaction = (json["totalTokensBeforeCompaction"] as? Int) ?? 0
            let contextUsed = (json["contextTokensUsed"] as? Int) ?? 0
            totalTokens += beforeCompaction + contextUsed

            if mtime > (lastSessionAt ?? Date.distantPast) {
                lastSessionAt = mtime
            }

            if let primary = (json["primaryModelId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !primary.isEmpty
            {
                modelCounts[primary, default: 0] += 1
            }
            if let models = json["modelsUsed"] as? [String] {
                for model in models {
                    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        modelCounts[trimmed, default: 0] += 1
                    }
                }
            }
        }

        let sortedModels = modelCounts.sorted { $0.value > $1.value }.map(\.key)
        return GrokLocalSessionSummary(
            sessionCount: sessionCount,
            totalTokens: totalTokens,
            lastSessionAt: lastSessionAt,
            primaryModel: sortedModels.first,
            models: sortedModels)
    }
}
