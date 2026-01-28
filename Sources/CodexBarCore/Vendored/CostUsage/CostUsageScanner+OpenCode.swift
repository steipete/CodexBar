import Foundation

extension CostUsageScanner {
    // MARK: - OpenCode

    /// Raw token data extracted from an OpenCode message file (provider-agnostic)
    struct OpenCodeTokenData: Sendable {
        let dayKey: String
        let modelID: String
        let providerID: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
    }

    struct OpenCodeParseResult: Sendable {
        let tokenData: OpenCodeTokenData?
        let providerID: String?
    }

    /// Parses an OpenCode message JSON file and extracts raw token usage (provider-agnostic).
    /// OpenCode stores each assistant message as a separate JSON file with structure:
    /// {
    ///   "time": { "created": 1769531159117 },
    ///   "role": "assistant",
    ///   "modelID": "claude-opus-4-5",
    ///   "providerID": "anthropic",
    ///   "tokens": { "input": 2, "output": 231, "reasoning": 0, "cache": { "read": 0, "write": 17135 } }
    /// }
    static func parseOpenCodeMessageFile(
        fileURL: URL,
        range: CostUsageDayRange) -> OpenCodeParseResult
    {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return OpenCodeParseResult(tokenData: nil, providerID: nil)
        }

        // Only process assistant messages with token usage
        guard (obj["role"] as? String) == "assistant" else {
            return OpenCodeParseResult(tokenData: nil, providerID: nil)
        }

        let providerID = obj["providerID"] as? String

        guard let tokens = obj["tokens"] as? [String: Any] else {
            return OpenCodeParseResult(tokenData: nil, providerID: providerID)
        }

        // Extract timestamp and convert to day key
        guard let time = obj["time"] as? [String: Any],
              let createdMs = time["created"] as? Int64
        else {
            return OpenCodeParseResult(tokenData: nil, providerID: providerID)
        }

        let createdDate = Date(timeIntervalSince1970: Double(createdMs) / 1000.0)
        let dayKey = CostUsageDayRange.dayKey(from: createdDate)

        guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey) else {
            return OpenCodeParseResult(tokenData: nil, providerID: providerID)
        }

        let modelID = obj["modelID"] as? String ?? "unknown"

        // Extract token counts
        func toInt(_ v: Any?) -> Int {
            if let n = v as? NSNumber { return n.intValue }
            return 0
        }

        let input = max(0, toInt(tokens["input"]))
        let output = max(0, toInt(tokens["output"]))
        let reasoning = max(0, toInt(tokens["reasoning"]))

        // Cache structure in OpenCode: { "read": N, "write": N }
        let cache = tokens["cache"] as? [String: Any]
        let cacheRead = max(0, toInt(cache?["read"]))
        let cacheWrite = max(0, toInt(cache?["write"]))

        // Skip if no tokens
        if input == 0, output == 0, cacheRead == 0, cacheWrite == 0, reasoning == 0 {
            return OpenCodeParseResult(tokenData: nil, providerID: providerID)
        }

        let tokenData = OpenCodeTokenData(
            dayKey: dayKey,
            modelID: modelID,
            providerID: providerID,
            inputTokens: input,
            outputTokens: output + reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite)

        return OpenCodeParseResult(tokenData: tokenData, providerID: providerID)
    }

    /// Normalizes OpenCode model IDs to match Claude pricing keys.
    /// OpenCode uses names like "claude-opus-4-5" while pricing uses "claude-opus-4-5-20251101".
    private static func normalizeClaudeModelID(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove provider prefix if present
        if trimmed.hasPrefix("anthropic/") {
            trimmed = String(trimmed.dropFirst("anthropic/".count))
        }

        // OpenCode model IDs don't have date suffixes, but the pricing table does.
        // Map known models to their dated versions for accurate pricing lookup.
        let modelMappings: [String: String] = [
            "claude-opus-4-5": "claude-opus-4-5-20251101",
            "claude-sonnet-4-5": "claude-sonnet-4-5-20250929",
            "claude-haiku-4-5": "claude-haiku-4-5-20251001",
            "claude-opus-4": "claude-opus-4-20250514",
            "claude-sonnet-4": "claude-sonnet-4-20250514",
            "claude-opus-4-1": "claude-opus-4-1",
        ]

        if let mapped = modelMappings[trimmed] {
            return mapped
        }

        // Fallback: use as-is (normalizeClaudeModel will handle it)
        return CostUsagePricing.normalizeClaudeModel(trimmed)
    }

    /// Converts raw token data to cache format with Claude pricing
    private static func packTokenDataForClaude(_ data: OpenCodeTokenData) -> (dayKey: String, model: String, packed: [Int]) {
        let normModel = self.normalizeClaudeModelID(data.modelID)

        let costScale = 1_000_000_000.0
        let cost = CostUsagePricing.claudeCostUSD(
            model: normModel,
            inputTokens: data.inputTokens,
            cacheReadInputTokens: data.cacheReadTokens,
            cacheCreationInputTokens: data.cacheWriteTokens,
            outputTokens: data.outputTokens)
        let costNanos = cost.map { Int(($0 * costScale).rounded()) } ?? 0

        // Pack tokens: [input, cacheRead, cacheWrite, output, costNanos]
        let packed = [data.inputTokens, data.cacheReadTokens, data.cacheWriteTokens, data.outputTokens, costNanos]
        return (data.dayKey, normModel, packed)
    }

    /// Process a single OpenCode message file directly into a cache
    private static func processOpenCodeMessageFileIntoCache(
        url: URL,
        size: Int64,
        mtimeMs: Int64,
        cache: inout CostUsageCache,
        touched: inout Set<String>,
        range: CostUsageDayRange)
    {
        let path = url.path
        touched.insert(path)

        // Check cache - if unchanged, skip
        if let cached = cache.files[path],
           cached.mtimeUnixMs == mtimeMs,
           cached.size == size
        {
            return
        }

        // Remove old cached data if present
        if let cached = cache.files[path] {
            Self.applyFileDays(cache: &cache, fileDays: cached.days, sign: -1)
        }

        // Parse the message file (provider-agnostic)
        let parsed = Self.parseOpenCodeMessageFile(fileURL: url, range: range)

        // Only include Anthropic provider messages when merging into Claude
        // For non-Anthropic files, store empty days to avoid re-parsing
        var days: [String: [String: [Int]]] = [:]
        if parsed.providerID == "anthropic", let tokenData = parsed.tokenData {
            let (dayKey, model, packed) = Self.packTokenDataForClaude(tokenData)
            days[dayKey] = [model: packed]
        }

        // Store in cache
        let usage = Self.makeFileUsage(
            mtimeUnixMs: mtimeMs,
            size: size,
            days: days,
            parsedBytes: size)
        cache.files[path] = usage
        Self.applyFileDays(cache: &cache, fileDays: usage.days, sign: 1)
    }

    /// Scans OpenCode message files and merges them into the Claude cache.
    /// This allows OpenCode usage (which consumes Claude Max subscription) to appear under Claude provider.
    static func scanOpenCodeMessagesIntoClaude(
        cache: inout CostUsageCache,
        touched: inout Set<String>,
        range: CostUsageDayRange,
        options: Options)
    {
        // If a custom openCodeStorageRoot is set, use it; otherwise use default
        let storageRoot: URL
        if let override = options.openCodeStorageRoot {
            storageRoot = override
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            storageRoot = home.appendingPathComponent(".local/share/opencode/storage", isDirectory: true)
        }
        let messageRoot = storageRoot.appendingPathComponent("message", isDirectory: true)

        guard FileManager.default.fileExists(atPath: messageRoot.path) else { return }

        // OpenCode stores messages in: message/{session_id}/msg_*.json
        guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
            at: messageRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return }

        for sessionDir in sessionDirs {
            guard let isDir = try? sessionDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir == true
            else { continue }

            guard let messageFiles = try? FileManager.default.contentsOfDirectory(
                at: sessionDir,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for messageFile in messageFiles {
                guard messageFile.pathExtension.lowercased() == "json",
                      messageFile.lastPathComponent.hasPrefix("msg_")
                else { continue }

                guard let values = try? messageFile.resourceValues(
                    forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                      values.isRegularFile == true
                else { continue }

                let size = Int64(values.fileSize ?? 0)
                if size <= 0 { continue }

                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let mtimeMs = Int64(mtime * 1000)

                Self.processOpenCodeMessageFileIntoCache(
                    url: messageFile,
                    size: size,
                    mtimeMs: mtimeMs,
                    cache: &cache,
                    touched: &touched,
                    range: range)
            }
        }
    }
}
