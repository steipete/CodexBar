import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum KiloProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kilo,
            metadata: ProviderMetadata(
                id: .kilo,
                displayName: "Kilo",
                sessionLabel: "Kilo Pass",
                weeklyLabel: "Plan",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Kilo credits",
                toggleTitle: "Show Kilo usage",
                cliName: "kilo",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://app.kilo.ai/usage",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kilo,
                iconResourceName: "ProviderIcon-kilo",
                color: ProviderColor(red: 249 / 255, green: 247 / 255, blue: 110 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "Kilo cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api, .cli],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    if context.sourceMode == .cli {
                        return [KiloCLIFetchStrategy()]
                    }
                    // Default: try web API first, then CLI fallback
                    return [KiloWebAPIFetchStrategy(), KiloCLIFetchStrategy()]
                })),
            cli: ProviderCLIConfig(
                name: "kilo",
                aliases: ["kilo-ai"],
                versionDetector: nil))
    }
}

struct KiloWebAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kilo.webapi"
    let kind: ProviderFetchKind = .apiToken

    private static let batchedURL = URL(string: "https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod?batch=1&input=%7B%220%22%3A%7B%7D%7D")!

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveAuthToken(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let token = Self.resolveAuthToken(environment: context.env) else {
            throw KiloAPIError.missingToken
        }

        var request = URLRequest(url: Self.batchedURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KiloAPIError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw KiloAPIError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // The batched response is an array, use JSONSerialization for flexible parsing
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              json.count >= 2 else {
            throw KiloAPIError.invalidResponse
        }

        // Response[0] = user.getCreditBlocks -> result.data has creditBlocks, totalBalance_mUsd
        // Response[1] = kiloPass.getState -> result.data has subscription
        
        let creditBlocksResponse = json[0]
        let creditBlocksResult = creditBlocksResponse["result"] as? [String: Any]
        let creditBlocksData = creditBlocksResult?["data"] as? [String: Any]
        let totalBalanceMUsd = creditBlocksData?["totalBalance_mUsd"] as? Int ?? 0

        // Parse individual credit blocks
        var creditBlocks: [KiloCreditBlock] = []
        if let blocksArray = creditBlocksData?["creditBlocks"] as? [[String: Any]] {
            let blockData = try JSONSerialization.data(withJSONObject: blocksArray)
            creditBlocks = (try? JSONDecoder().decode([KiloCreditBlock].self, from: blockData)) ?? []
        }

        let kiloPassResponse = json[1]
        let kiloPassResult = kiloPassResponse["result"] as? [String: Any]
        let kiloPassData = kiloPassResult?["data"] as? [String: Any]
        let subscriptionData = kiloPassData?["subscription"] as? [String: Any]

        // Parse auto-top-up from credit blocks response
        let autoTopUpEnabled = creditBlocksData?["autoTopUpEnabled"] as? Bool ?? false

        // Try to parse response[2] for auto-top-up payment method details
        var autoTopUpAmountDollars: Double = 0
        if json.count >= 3 {
            let autoTopUpResponse = json[2]
            let autoTopUpResult = autoTopUpResponse["result"] as? [String: Any]
            let autoTopUpData = autoTopUpResult?["data"] as? [String: Any]
            if let amountCents = autoTopUpData?["amountCents"] as? Int {
                autoTopUpAmountDollars = Double(amountCents) / 100.0
            } else if let amount = autoTopUpData?["amount"] as? Double {
                autoTopUpAmountDollars = amount
            }
        }

        let autoTopUp: KiloAutoTopUp? = autoTopUpEnabled
            ? KiloAutoTopUp(enabled: true, amountDollars: autoTopUpAmountDollars)
            : nil

        let totalBalanceDollars = Double(totalBalanceMUsd) / 1_000_000.0

        // Parse subscription data
        var periodUsageDollars: Double = 0
        var periodBaseCredits: Double = 0
        var periodBonusCredits: Double = 0
        var periodResetsAt: Date? = nil
        var planName: String? = nil

        if let sub = subscriptionData {
            periodUsageDollars = sub["currentPeriodUsageUsd"] as? Double ?? 0
            periodBaseCredits = sub["currentPeriodBaseCreditsUsd"] as? Double ?? 0
            periodBonusCredits = sub["currentPeriodBonusCreditsUsd"] as? Double ?? 0

            // Derive plan name from tier (tier_19 → Starter, tier_49 → Pro, tier_199 → Expert)
            let tier = sub["tier"] as? String
            let knownTiers: [String: String] = [
                "tier_19": "Starter",
                "tier_49": "Pro",
                "tier_199": "Expert",
            ]
            if let tier {
                planName = knownTiers[tier] ?? tier
            } else {
                planName = "Kilo Pass"
            }

            // Parse next billing date
            if let nextBilling = sub["nextBillingAt"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: nextBilling) {
                    periodResetsAt = date
                } else {
                    // Try without fractional seconds
                    formatter.formatOptions = [.withInternetDateTime]
                    periodResetsAt = formatter.date(from: nextBilling)
                }
            }
        }

        // Try to get CLI stats for additional info
        var cliCost: Double = 0
        var cliSessions: Int = 0
        var cliMessages: Int = 0
        
        var cliInputTokens: Int = 0
        var cliOutputTokens: Int = 0
        var cliCacheReadTokens: Int = 0

        if let cliOutput = try? await KiloCLIFetchStrategy.runKiloStatsInternal(env: [:]) {
            let parsed = KiloCLIFetchStrategy.parseCLIStatsOutputInternal(cliOutput)
            cliCost = parsed.totalCost
            cliSessions = parsed.sessions
            cliMessages = parsed.messages
            cliInputTokens = parsed.inputTokens
            cliOutputTokens = parsed.outputTokens
            cliCacheReadTokens = parsed.cacheReadTokens
        }
        
        let snapshot = KiloUsageSnapshot(
            balanceDollars: totalBalanceDollars,
            periodBaseCredits: periodBaseCredits,
            periodBonusCredits: periodBonusCredits,
            periodUsageDollars: periodUsageDollars,
            periodResetsAt: periodResetsAt,
            hasSubscription: subscriptionData != nil,
            planName: planName,
            creditBlocks: creditBlocks,
            autoTopUp: autoTopUp,
            cliCostDollars: cliCost,
            cliSessions: cliSessions,
            cliMessages: cliMessages,
            cliInputTokens: cliInputTokens,
            cliOutputTokens: cliOutputTokens,
            cliCacheReadTokens: cliCacheReadTokens,
            updatedAt: Date())

        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        true
    }

    private static func resolveAuthToken(environment: [String: String]) -> String? {
        // KILO_API_KEY env var (or settings override) takes priority
        if let token = ProviderTokenResolver.kiloToken(environment: environment) {
            return token
        }
        // Fall back to Kilo CLI's auth.json session token
        let authFilePath = NSHomeDirectory() + "/.local/share/kilo/auth.json"
        guard let data = FileManager.default.contents(atPath: authFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kilo = json["kilo"] as? [String: Any],
              let access = kilo["access"] as? String
        else {
            return nil
        }
        return access
    }

}

struct KiloCLIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kilo.cli"
    let kind: ProviderFetchKind = .cli

    private static let logger = CodexBarLog.logger(LogCategories.kiloCLI)

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        Self.locateKiloBinary() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let output = try await Self.runKiloStatsInternal(env: context.env)
        let snapshot = try Self.parseStatsOutput(output)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "cli")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if error is KiloCLIError {
            return false
        }
        return true
    }

    static func runKiloStatsInternal(env: [String: String]) async throws -> String {
        var fullEnv = env
        fullEnv["PATH"] = PathBuilder.effectivePATH(
            purposes: [.tty, .nodeTooling],
            env: fullEnv)

        let result = try await SubprocessRunner.run(
            binary: "/usr/bin/env",
            arguments: ["kilo", "stats"],
            environment: fullEnv,
            timeout: 10.0,
            label: "kilo-stats")

        guard result.stdout.isEmpty == false else {
            throw KiloCLIError.parseError("Empty output")
        }

        return result.stdout
    }

    struct CLIStats {
        var totalCost: Double = 0
        var sessions: Int = 0
        var messages: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
    }

    static func parseCLIStatsOutputInternal(_ output: String) -> CLIStats {
        let lines = output.components(separatedBy: .newlines)
        var stats = CLIStats()

        for line in lines {
            let asciiLine = line.unicodeScalars
                .filter { $0.value < 128 }
                .map { String($0) }
                .joined()

            if asciiLine.contains("Total Cost") {
                if let range = asciiLine.range(of: "\\$([0-9.]+)", options: .regularExpression) {
                    stats.totalCost = Double(String(asciiLine[range].dropFirst())) ?? 0
                }
            } else if asciiLine.contains("Sessions") {
                stats.sessions = Self.parseIntField(asciiLine, key: "Sessions")
            } else if asciiLine.contains("Messages") {
                stats.messages = Self.parseIntField(asciiLine, key: "Messages")
            } else if Self.lineStartsWith(asciiLine, key: "Input") {
                stats.inputTokens = Self.parseSuffixedNumber(asciiLine)
            } else if Self.lineStartsWith(asciiLine, key: "Output") {
                stats.outputTokens = Self.parseSuffixedNumber(asciiLine)
            } else if asciiLine.contains("Cache Read") {
                stats.cacheReadTokens = Self.parseSuffixedNumber(asciiLine)
            }
        }

        return stats
    }

    /// Parse "1.4M" / "46.1K" / "20.2M" / "0" style token counts.
    private static func parseSuffixedNumber(_ line: String) -> Int {
        let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let last = components.last else { return 0 }
        return Self.parseTokenCount(last)
    }

    static func parseTokenCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "0" { return 0 }
        let multipliers: [(String, Double)] = [("B", 1_000_000_000), ("M", 1_000_000), ("K", 1_000)]
        for (suffix, mult) in multipliers {
            if trimmed.hasSuffix(suffix), let num = Double(trimmed.dropLast(suffix.count)) {
                return Int(num * mult)
            }
        }
        return Int(trimmed) ?? 0
    }

    /// Check if a line's first non-whitespace word matches the key exactly.
    private static func lineStartsWith(_ line: String, key: String) -> Bool {
        let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return components.first == key
    }

    private static func parseIntField(_ line: String, key: String) -> Int {
        let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if let idx = components.firstIndex(of: key), idx + 1 < components.count {
            return Int(components[idx + 1]) ?? 0
        }
        return 0
    }

    private static func locateKiloBinary() -> String? {
        if let path = TTYCommandRunner.which("kilo") {
            return path
        }
        return ShellCommandLocator.commandV("kilo", "/bin/zsh", 2.0, FileManager.default)
    }

    private static func parseStatsOutput(_ output: String) throws -> KiloUsageSnapshot {
        let stats = Self.parseCLIStatsOutputInternal(output)
        return KiloUsageSnapshot(
            cliCostDollars: stats.totalCost,
            cliSessions: stats.sessions,
            cliMessages: stats.messages,
            cliInputTokens: stats.inputTokens,
            cliOutputTokens: stats.outputTokens,
            cliCacheReadTokens: stats.cacheReadTokens,
            updatedAt: Date())
    }
}

public enum KiloCLIError: LocalizedError, Sendable {
    case cliNotFound
    case cliFailed(String)
    case parseError(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "kilo CLI not found. Install it with npm install -g @kilocode/cli"
        case let .cliFailed(message):
            message
        case let .parseError(message):
            "Failed to parse Kilo stats: \(message)"
        case .timeout:
            "Kilo CLI timed out."
        }
    }
}

public struct KiloCreditBlock: Codable, Sendable {
    public let id: String
    public let effectiveDateString: String
    public let expiryDateString: String?
    public let balanceMUsd: Int
    public let amountMUsd: Int
    public let isFree: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case effectiveDateString = "effective_date"
        case expiryDateString = "expiry_date"
        case balanceMUsd = "balance_mUsd"
        case amountMUsd = "amount_mUsd"
        case isFree = "is_free"
    }

    /// Balance in dollars.
    public var balanceDollars: Double { Double(balanceMUsd) / 1_000_000.0 }
    /// Original amount in dollars.
    public var amountDollars: Double { Double(amountMUsd) / 1_000_000.0 }
    /// Remaining fraction (0…1).
    public var remainingFraction: Double {
        guard amountMUsd > 0 else { return 0 }
        return Double(balanceMUsd) / Double(amountMUsd)
    }

    /// Parsed effective date.
    public var effectiveDate: Date? { Self.parseDate(effectiveDateString) }
    /// Parsed expiry date.
    public var expiryDate: Date? { expiryDateString.flatMap { Self.parseDate($0) } }

    private static func parseDate(_ string: String) -> Date? {
        // "2026-02-15 21:33:29.596883+00" or ISO8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        // Postgres-style with space separator
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZ"
        if let d = df.date(from: string) { return d }
        df.dateFormat = "yyyy-MM-dd HH:mm:ssZZZ"
        return df.date(from: string)
    }
}
