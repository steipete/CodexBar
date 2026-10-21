import Foundation
#if os(macOS) && canImport(FoundationXML)
import FoundationXML
#endif

public struct JetBrainsQuotaInfo: Sendable, Equatable {
    public let type: String?
    public let used: Double
    public let maximum: Double
    public let available: Double
    public let until: Date?
    /// Purchased top-up credits, kept apart from the monthly tariff balance above.
    public let topUp: JetBrainsTopUpQuota?

    public init(
        type: String?,
        used: Double,
        maximum: Double,
        available: Double?,
        until: Date?,
        topUp: JetBrainsTopUpQuota? = nil)
    {
        self.type = type
        self.used = used
        self.maximum = maximum
        // Use available if provided, otherwise calculate from maximum - used
        self.available = available ?? max(0, maximum - used)
        self.until = until
        self.topUp = topUp
    }

    /// Percentage of quota that has been used (0-100)
    public var usedPercent: Double {
        guard self.maximum > 0 else { return 0 }
        return min(100, max(0, (self.used / self.maximum) * 100))
    }

    /// Percentage of quota remaining (0-100), based on available value
    public var remainingPercent: Double {
        guard self.maximum > 0 else { return 100 }
        return min(100, max(0, (self.available / self.maximum) * 100))
    }
}

public struct JetBrainsTopUpQuota: Sendable, Equatable {
    /// The IDE stores 1.00 displayed credit as 100,000 quota units (10.00 monthly credits = 1,000,000).
    public static let unitsPerCredit: Double = 100_000

    public let maximum: Double
    public let available: Double

    /// Only finite, nonnegative balances with a positive maximum describe purchased credits.
    public init?(maximum: Double?, available: Double?) {
        guard let maximum, maximum.isFinite, maximum > 0,
              let available, available.isFinite, available >= 0 else { return nil }
        self.maximum = maximum
        self.available = min(available, maximum)
    }

    public var availableCredits: Double {
        self.available / Self.unitsPerCredit
    }
}

public struct JetBrainsRefillInfo: Sendable, Equatable {
    public let type: String?
    public let next: Date?
    public let amount: Double?
    public let duration: String?

    public init(type: String?, next: Date?, amount: Double?, duration: String?) {
        self.type = type
        self.next = next
        self.amount = amount
        self.duration = duration
    }
}

public struct JetBrainsStatusSnapshot: Sendable {
    public let quotaInfo: JetBrainsQuotaInfo
    public let refillInfo: JetBrainsRefillInfo?
    public let detectedIDE: JetBrainsIDEInfo?

    public init(quotaInfo: JetBrainsQuotaInfo, refillInfo: JetBrainsRefillInfo?, detectedIDE: JetBrainsIDEInfo?) {
        self.quotaInfo = quotaInfo
        self.refillInfo = refillInfo
        self.detectedIDE = detectedIDE
    }

    public func toUsageSnapshot() throws -> UsageSnapshot {
        // Primary shows monthly credits usage with next refill date
        // IDE displays: "今月のクレジット残り X / Y" with "Z月D日に更新されます"
        let refillDate = self.refillInfo?.next
        let primary = RateWindow(
            usedPercent: self.quotaInfo.usedPercent,
            windowMinutes: nil,
            resetsAt: refillDate,
            resetDescription: UsageFormatter.compactResetDescription(refillDate))

        let identity = ProviderIdentitySnapshot(
            providerID: .jetbrains,
            accountEmail: nil,
            accountOrganization: self.detectedIDE?.displayName,
            loginMethod: self.quotaInfo.type)

        // Top-up credits are a balance, not a window: JetBrains only spends them after the monthly quota.
        let details = try self.quotaInfo.topUp.map { topUp in
            try [ProviderDetailSection(title: "Top-up credits", rows: [
                ProviderDetailSection.Row(
                    label: "Remaining",
                    value: String(format: "%.2f credits", topUp.availableCredits)),
            ])]
        } ?? []

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            details: details,
            updatedAt: Date(),
            identity: identity)
    }
}

public enum JetBrainsStatusProbeError: LocalizedError, Sendable, Equatable {
    case noIDEDetected
    case quotaFileNotFound(String)
    case parseError(String)
    case noQuotaInfo

    public var errorDescription: String? {
        switch self {
        case .noIDEDetected:
            "No JetBrains IDE with AI Assistant detected. Install a JetBrains IDE and enable AI Assistant."
        case let .quotaFileNotFound(path):
            "JetBrains AI quota file not found at \(path). Enable AI Assistant in your IDE."
        case let .parseError(message):
            "Could not parse JetBrains AI quota: \(message)"
        case .noQuotaInfo:
            "No quota information found in the JetBrains AI configuration."
        }
    }
}

public struct JetBrainsStatusProbe: Sendable {
    private let settings: ProviderSettingsSnapshot?
    private let detectIDEs: @Sendable (_ includeMissingQuota: Bool) -> [JetBrainsIDEInfo]
    private let readLogEntry: @Sendable (_ ideBasePath: String) -> JetBrainsQuotaLogReader.Entry?

    public init(settings: ProviderSettingsSnapshot? = nil) {
        self.init(
            settings: settings,
            detectIDEs: { JetBrainsIDEDetector.detectInstalledIDEs(includeMissingQuota: $0) },
            readLogEntry: {
                JetBrainsQuotaLogReader.logFilePath(forIDEBasePath: $0)
                    .flatMap { JetBrainsQuotaLogReader.latestEntry(atPath: $0) }
            })
    }

    init(
        settings: ProviderSettingsSnapshot?,
        detectIDEs: @escaping @Sendable (_ includeMissingQuota: Bool) -> [JetBrainsIDEInfo],
        readLogEntry: @escaping @Sendable (_ ideBasePath: String) -> JetBrainsQuotaLogReader.Entry?)
    {
        self.settings = settings
        self.detectIDEs = detectIDEs
        self.readLogEntry = readLogEntry
    }

    public func fetch() async throws -> JetBrainsStatusSnapshot {
        let quotaFilePath: String
        let detectedIDE: JetBrainsIDEInfo?
        do {
            (quotaFilePath, detectedIDE) = try self.resolveQuotaFilePath()
        } catch JetBrainsStatusProbeError.noIDEDetected {
            return try self.logOnlySnapshot()
        }
        let basePath = URL(fileURLWithPath: quotaFilePath).deletingLastPathComponent().deletingLastPathComponent().path
        let logEntry = self.readLogEntry(basePath)

        let snapshot: JetBrainsStatusSnapshot
        do {
            snapshot = try Self.parseQuotaFile(at: quotaFilePath, detectedIDE: detectedIDE)
        } catch {
            guard let logEntry else { throw error }
            return JetBrainsStatusSnapshot(
                quotaInfo: logEntry.quotaInfo,
                refillInfo: logEntry.refillInfo,
                detectedIDE: detectedIDE)
        }

        let quotaFileModifiedAt = JetBrainsIDEDetector.quotaModificationDate(at: quotaFilePath)
        return Self.applyingLogEntry(logEntry, to: snapshot, quotaFileModifiedAt: quotaFileModifiedAt)
    }

    /// Auto-detect with no quota XML anywhere: an IDE may still have logged its quota state.
    private func logOnlySnapshot() throws -> JetBrainsStatusSnapshot {
        let latest = self.detectIDEs(true)
            .compactMap { ide in self.readLogEntry(ide.basePath).map { (ide: ide, entry: $0) } }
            .max { $0.entry.timestamp < $1.entry.timestamp }
        guard let latest else { throw JetBrainsStatusProbeError.noIDEDetected }
        return JetBrainsStatusSnapshot(
            quotaInfo: latest.entry.quotaInfo,
            refillInfo: latest.entry.refillInfo,
            detectedIDE: latest.ide)
    }

    /// The IDE persists the quota XML rarely; prefer the log when it was written after the XML.
    static func applyingLogEntry(
        _ logEntry: JetBrainsQuotaLogReader.Entry?,
        to snapshot: JetBrainsStatusSnapshot,
        quotaFileModifiedAt: Date?) -> JetBrainsStatusSnapshot
    {
        guard let logEntry, let quotaFileModifiedAt, logEntry.timestamp > quotaFileModifiedAt else { return snapshot }
        return JetBrainsStatusSnapshot(
            quotaInfo: logEntry.quotaInfo,
            refillInfo: logEntry.refillInfo,
            detectedIDE: snapshot.detectedIDE)
    }

    private func resolveQuotaFilePath() throws -> (String, JetBrainsIDEInfo?) {
        if let customPath = self.settings?.jetbrainsIDEBasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty
        {
            let expandedBasePath = (customPath as NSString).expandingTildeInPath
            let quotaPath = JetBrainsIDEDetector.quotaFilePath(for: expandedBasePath)
            return (quotaPath, nil)
        }

        guard let detectedIDE = JetBrainsIDEDetector.latestIDE(in: self.detectIDEs(false)) else {
            throw JetBrainsStatusProbeError.noIDEDetected
        }
        return (detectedIDE.quotaFilePath, detectedIDE)
    }

    public static func parseQuotaFile(
        at path: String,
        detectedIDE: JetBrainsIDEInfo?) throws -> JetBrainsStatusSnapshot
    {
        guard FileManager.default.fileExists(atPath: path) else {
            throw JetBrainsStatusProbeError.quotaFileNotFound(path)
        }

        let xmlData: Data
        do {
            xmlData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw JetBrainsStatusProbeError.parseError("Failed to read file: \(error.localizedDescription)")
        }

        return try Self.parseXMLData(xmlData, detectedIDE: detectedIDE)
    }

    public static func parseXMLData(_ data: Data, detectedIDE: JetBrainsIDEInfo?) throws -> JetBrainsStatusSnapshot {
        #if os(macOS)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw JetBrainsStatusProbeError.parseError("Invalid XML: \(error.localizedDescription)")
        }

        let quotaInfoRaw = try? document
            .nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option[@name='quotaInfo']/@value")
            .first?
            .stringValue
        let nextRefillRaw = try? document
            .nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option[@name='nextRefill']/@value")
            .first?
            .stringValue
        #else
        let parseResult = JetBrainsXMLParser.parse(data: data)
        let quotaInfoRaw = parseResult.quotaInfo
        let nextRefillRaw = parseResult.nextRefill
        #endif

        guard let quotaInfoRaw, !quotaInfoRaw.isEmpty else {
            throw JetBrainsStatusProbeError.noQuotaInfo
        }

        let quotaInfoDecoded = Self.decodeHTMLEntities(quotaInfoRaw)
        let quotaInfo = try Self.parseQuotaInfoJSON(quotaInfoDecoded)

        var refillInfo: JetBrainsRefillInfo?
        if let nextRefillRaw, !nextRefillRaw.isEmpty {
            let nextRefillDecoded = Self.decodeHTMLEntities(nextRefillRaw)
            refillInfo = try? Self.parseRefillInfoJSON(nextRefillDecoded)
        }

        return JetBrainsStatusSnapshot(
            quotaInfo: quotaInfo,
            refillInfo: refillInfo,
            detectedIDE: detectedIDE)
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func parseQuotaInfoJSON(_ jsonString: String) throws -> JetBrainsQuotaInfo {
        let json = try Self.parseJSONObject(jsonString)
        // Select one balance: monthly values must never be paired with totals that include top-ups.
        let tariffQuota = (json["tariffQuota"] as? [String: Any]).flatMap { quota in
            ["current", "maximum"].allSatisfy { key in
                (quota[key] as? String).flatMap(Double.init)?.isFinite == true
            } ? quota : nil
        }
        let quota = tariffQuota ?? json
        let topUpQuota = json["topUpQuota"] as? [String: Any]
        let topUpValue = { (key: String) in (topUpQuota?[key] as? String).flatMap(Double.init) }
        return JetBrainsQuotaInfo(
            type: json["type"] as? String,
            used: (quota["current"] as? String).flatMap(Double.init) ?? 0,
            maximum: (quota["maximum"] as? String).flatMap(Double.init) ?? 0,
            available: (tariffQuota?["available"] as? String).flatMap(Double.init),
            until: ISO8601DateParser.parse(json["until"] as? String),
            topUp: JetBrainsTopUpQuota(
                maximum: topUpValue("maximum"),
                available: topUpValue("available")))
    }

    private static func parseRefillInfoJSON(_ jsonString: String) throws -> JetBrainsRefillInfo {
        let json = try Self.parseJSONObject(jsonString)
        let tariff = json["tariff"] as? [String: Any]
        return JetBrainsRefillInfo(
            type: json["type"] as? String,
            next: ISO8601DateParser.parse(json["next"] as? String),
            amount: (json["amount"] as? String).flatMap(Double.init)
                ?? (tariff?["amount"] as? String).flatMap(Double.init),
            duration: json["duration"] as? String ?? tariff?["duration"] as? String)
    }

    private static func parseJSONObject(_ string: String) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else {
            throw JetBrainsStatusProbeError.parseError("Invalid JSON format")
        }
        return json
    }
}

/// Simple regex-based XML parser to avoid libxml2 dependency on Linux.
/// Only extracts quotaInfo and nextRefill values from AIAssistantQuotaManager2 component.
enum JetBrainsXMLParser {
    struct ParseResult {
        let quotaInfo: String?
        let nextRefill: String?
    }

    static func parse(data: Data) -> ParseResult {
        guard let content = String(data: data, encoding: .utf8) else {
            return ParseResult(quotaInfo: nil, nextRefill: nil)
        }

        let pattern = #"<component[^>]*name\s*=\s*["']AIAssistantQuotaManager2["'][^>]*>[\s\S]*?</component>"#
        guard let componentContent = self.firstMatch(pattern, in: content) else {
            return ParseResult(quotaInfo: nil, nextRefill: nil)
        }

        let quotaInfo = self.extractOptionValue(named: "quotaInfo", from: componentContent)
        let nextRefill = self.extractOptionValue(named: "nextRefill", from: componentContent)

        return ParseResult(quotaInfo: quotaInfo, nextRefill: nextRefill)
    }

    private static func firstMatch(_ pattern: String, in content: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: group), in: content)
        else { return nil }
        return String(content[range])
    }

    private static func extractOptionValue(named name: String, from content: String) -> String? {
        // Match <option name="NAME" value="VALUE"/> or <option value="VALUE" name="NAME"/>
        let patterns = [
            #"<option[^>]*name\s*=\s*["']\#(name)["'][^>]*value\s*=\s*["']([^"']*)["']"#,
            #"<option[^>]*value\s*=\s*["']([^"']*)["'][^>]*name\s*=\s*["']\#(name)["']"#,
        ]

        for pattern in patterns {
            if let value = self.firstMatch(pattern, in: content, group: 1) { return value }
        }

        return nil
    }
}
