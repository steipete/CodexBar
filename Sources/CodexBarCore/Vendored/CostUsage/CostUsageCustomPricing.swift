#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// User overlay for list-price estimates. Values are USD per million tokens.
/// Exact key match only; `0` is free; a missing field stays unknown and is not
/// filled from models.dev or bundled tables.
public struct CostUsageCustomPricing: Sendable, Equatable {
    public struct Rates: Sendable, Equatable {
        public var input: Double?
        public var output: Double?
        public var cacheRead: Double?
        public var cacheWrite: Double?

        public init(input: Double? = nil, output: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }

        public var hasAnyRate: Bool {
            self.input != nil || self.output != nil || self.cacheRead != nil || self.cacheWrite != nil
        }
    }

    public let entries: [String: Rates]
    public let fingerprint: String

    public init(entries: [String: Rates], fingerprint: String) {
        self.entries = entries
        self.fingerprint = fingerprint
    }

    public static let empty = CostUsageCustomPricing(entries: [:], fingerprint: "none")

    public static let fileName = "custom-pricing.json"

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        AppGroupSupport.localFallbackDirectory(fileManager: fileManager)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }

    public static func load(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> CostUsageCustomPricing
    {
        if fileURL == nil, self.isRunningTests(environment) {
            return .empty
        }
        let url = fileURL ?? self.defaultFileURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return .empty }
        return self.parse(data)
    }

    private static func isRunningTests(_ environment: [String: String]) -> Bool {
        let keys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "SWIFT_TESTING_ENABLED",
            "TESTING_LIBRARY_VERSION",
            "SWIFT_TESTING",
        ]
        if keys.contains(where: { environment[$0] != nil }) {
            return true
        }
        if keys.contains(where: { ProcessInfo.processInfo.environment[$0] != nil }) {
            return true
        }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }

    public static func parse(_ data: Data) -> CostUsageCustomPricing {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        var entries: [String: Rates] = [:]
        for (rawKey, rawValue) in object {
            let key = self.normalizeKey(rawKey)
            guard !key.isEmpty, let rates = self.rates(from: rawValue) else { continue }
            entries[key] = rates
        }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CostUsageCustomPricing(entries: entries, fingerprint: fingerprint)
    }

    public func rates(providerID: String? = nil, model: String) -> Rates? {
        let modelKey = Self.normalizeKey(model)
        guard !modelKey.isEmpty else { return nil }
        if let exact = self.entries[modelKey] {
            return exact
        }
        if let providerID {
            let combined = Self.normalizeKey("\(providerID)/\(model)")
            if let match = self.entries[combined] {
                return match
            }
        }
        return nil
    }

    public func costUSD(
        providerID: String? = nil,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0) -> Double?
    {
        guard let rates = self.rates(providerID: providerID, model: model) else { return nil }
        return Self.costUSD(
            rates: rates,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens)
    }

    func estimatedCodexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        cacheWriteInputTokens: Int) -> Double?
    {
        let cached = max(0, cachedInputTokens)
        let written = max(0, cacheWriteInputTokens)
        let uncachedInput = max(0, inputTokens - cached - written)
        return self.costUSD(
            providerID: CostUsagePricing.codexModelsDevProviderID,
            model: model,
            inputTokens: uncachedInput,
            outputTokens: outputTokens,
            cacheReadTokens: cached,
            cacheWriteTokens: written)
    }

    static func costUSD(
        rates: Rates,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int) -> Double?
    {
        var total = 0.0
        if inputTokens > 0 {
            guard let rate = rates.input else { return nil }
            total += Double(inputTokens) * Self.perToken(rate)
        }
        if outputTokens > 0 {
            guard let rate = rates.output else { return nil }
            total += Double(outputTokens) * Self.perToken(rate)
        }
        if cacheReadTokens > 0 {
            guard let rate = rates.cacheRead else { return nil }
            total += Double(cacheReadTokens) * Self.perToken(rate)
        }
        if cacheWriteTokens > 0 {
            guard let rate = rates.cacheWrite else { return nil }
            total += Double(cacheWriteTokens) * Self.perToken(rate)
        }
        return total
    }

    public static func perToken(_ perMillion: Double) -> Double {
        perMillion / 1_000_000
    }

    static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func rates(from value: Any) -> Rates? {
        guard let object = value as? [String: Any] else { return nil }
        let rates = Rates(
            input: self.rate(object["input"]),
            output: self.rate(object["output"]),
            cacheRead: self.rate(object["cacheRead"]) ?? self.rate(object["cache_read"]),
            cacheWrite: self.rate(object["cacheWrite"])
                ?? self.rate(object["cache_write"])
                ?? self.rate(object["cacheCreation"])
                ?? self.rate(object["cache_creation"]))
        return rates.hasAnyRate ? rates : nil
    }

    /// `0` is a valid free rate. Non-finite and negative values are unknown.
    private static func rate(_ value: Any?) -> Double? {
        guard let value else { return nil }
        let number: Double
        if let parsed = value as? Double {
            number = parsed
        } else if let parsed = value as? Int {
            number = Double(parsed)
        } else if let parsed = value as? NSNumber {
            number = parsed.doubleValue
        } else {
            return nil
        }
        guard number.isFinite, number >= 0 else { return nil }
        return number
    }
}
