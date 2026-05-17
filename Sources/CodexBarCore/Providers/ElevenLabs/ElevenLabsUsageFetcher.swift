import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ElevenLabsOverage: Codable, Sendable, Equatable {
    public let amount: String?
    public let currency: String?
}

public struct ElevenLabsSubscriptionResponse: Decodable, Sendable {
    public let tier: String?
    public let characterCount: Int
    public let characterLimit: Int
    public let voiceSlotsUsed: Int?
    public let professionalVoiceSlotsUsed: Int?
    public let voiceLimit: Int?
    public let professionalVoiceLimit: Int?
    public let currentOverage: ElevenLabsOverage?
    public let status: String?
    public let nextCharacterCountResetUnix: Int?

    private enum CodingKeys: String, CodingKey {
        case tier
        case characterCount = "character_count"
        case characterLimit = "character_limit"
        case voiceSlotsUsed = "voice_slots_used"
        case professionalVoiceSlotsUsed = "professional_voice_slots_used"
        case voiceLimit = "voice_limit"
        case professionalVoiceLimit = "professional_voice_limit"
        case currentOverage = "current_overage"
        case status
        case nextCharacterCountResetUnix = "next_character_count_reset_unix"
    }
}

public struct ElevenLabsUsageSnapshot: Codable, Sendable, Equatable {
    public let tier: String?
    public let characterCount: Int
    public let characterLimit: Int
    public let voiceSlotsUsed: Int?
    public let professionalVoiceSlotsUsed: Int?
    public let voiceLimit: Int?
    public let professionalVoiceLimit: Int?
    public let currentOverage: ElevenLabsOverage?
    public let status: String?
    public let resetsAt: Date?
    public let updatedAt: Date

    public init(
        tier: String?,
        characterCount: Int,
        characterLimit: Int,
        voiceSlotsUsed: Int?,
        professionalVoiceSlotsUsed: Int?,
        voiceLimit: Int?,
        professionalVoiceLimit: Int?,
        currentOverage: ElevenLabsOverage?,
        status: String?,
        resetsAt: Date?,
        updatedAt: Date)
    {
        self.tier = tier
        self.characterCount = characterCount
        self.characterLimit = characterLimit
        self.voiceSlotsUsed = voiceSlotsUsed
        self.professionalVoiceSlotsUsed = professionalVoiceSlotsUsed
        self.voiceLimit = voiceLimit
        self.professionalVoiceLimit = professionalVoiceLimit
        self.currentOverage = currentOverage
        self.status = status
        self.resetsAt = resetsAt
        self.updatedAt = updatedAt
    }

    public var usedPercent: Double {
        guard self.characterLimit > 0 else { return 0 }
        return max(0, Double(self.characterCount) / Double(self.characterLimit) * 100)
    }

    public var remainingCharacters: Int {
        max(0, self.characterLimit - self.characterCount)
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let primary = RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: nil,
            resetsAt: self.resetsAt,
            resetDescription: self.characterSummary)
        let extraWindows = self.voiceWindows()
        let identity = ProviderIdentitySnapshot(
            providerID: .elevenlabs,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: self.displayTier)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: extraWindows.isEmpty ? nil : extraWindows,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    private var displayTier: String? {
        guard let tier = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !tier.isEmpty else {
            return status
        }
        let statusSuffix = if let status, !status.isEmpty, status.lowercased() != "active" {
            " · \(status)"
        } else {
            ""
        }
        return "\(tier.replacingOccurrences(of: "_", with: " ").capitalized)\(statusSuffix)"
    }

    private var characterSummary: String {
        "\(Self.formatCount(self.characterCount)) / \(Self.formatCount(self.characterLimit)) credits"
    }

    private func voiceWindows() -> [NamedRateWindow] {
        var windows: [NamedRateWindow] = []
        if let used = voiceSlotsUsed, let limit = voiceLimit, limit > 0 {
            windows.append(NamedRateWindow(
                id: "voice-slots",
                title: "Voice slots",
                window: RateWindow(
                    usedPercent: Double(used) / Double(limit) * 100,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "\(used) / \(limit)")))
        }
        if let used = professionalVoiceSlotsUsed, let limit = professionalVoiceLimit, limit > 0 {
            windows.append(NamedRateWindow(
                id: "professional-voices",
                title: "Professional voices",
                window: RateWindow(
                    usedPercent: Double(used) / Double(limit) * 100,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: "\(used) / \(limit)")))
        }
        return windows
    }

    private static func formatCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

public enum ElevenLabsUsageError: LocalizedError, Sendable {
    case missingCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing ElevenLabs API key. Set apiKey in ~/.codexbar/config.json or ELEVENLABS_API_KEY."
        case let .networkError(message):
            "ElevenLabs network error: \(message)"
        case let .apiError(message):
            "ElevenLabs API error: \(message)"
        case let .parseFailed(message):
            "Failed to parse ElevenLabs response: \(message)"
        }
    }
}

public struct ElevenLabsUsageFetcher: Sendable {
    private static let log = CodexBarLog.logger(LogCategories.elevenLabsUsage)
    private static let timeoutSeconds: TimeInterval = 15

    public static func fetchUsage(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ElevenLabsUsageSnapshot
    {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ElevenLabsUsageError.missingCredentials
        }

        let url = Self.subscriptionURL(baseURL: ElevenLabsSettingsReader.apiURL(environment: environment))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(trimmed, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeoutSeconds

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsUsageError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return try Self.parseSnapshot(data: data, updatedAt: Date())
        case 401, 403:
            throw ElevenLabsUsageError.missingCredentials
        default:
            Self.log.error("ElevenLabs API returned \(httpResponse.statusCode)")
            throw ElevenLabsUsageError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }

    static func _parseSnapshotForTesting(_ data: Data, updatedAt: Date) throws -> ElevenLabsUsageSnapshot {
        try self.parseSnapshot(data: data, updatedAt: updatedAt)
    }

    private static func parseSnapshot(data: Data, updatedAt: Date) throws -> ElevenLabsUsageSnapshot {
        let decoded: ElevenLabsSubscriptionResponse
        do {
            decoded = try JSONDecoder().decode(ElevenLabsSubscriptionResponse.self, from: data)
        } catch {
            throw ElevenLabsUsageError.parseFailed(error.localizedDescription)
        }

        let resetsAt = decoded.nextCharacterCountResetUnix.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }

        return ElevenLabsUsageSnapshot(
            tier: decoded.tier,
            characterCount: decoded.characterCount,
            characterLimit: decoded.characterLimit,
            voiceSlotsUsed: decoded.voiceSlotsUsed,
            professionalVoiceSlotsUsed: decoded.professionalVoiceSlotsUsed,
            voiceLimit: decoded.voiceLimit,
            professionalVoiceLimit: decoded.professionalVoiceLimit,
            currentOverage: decoded.currentOverage,
            status: decoded.status,
            resetsAt: resetsAt,
            updatedAt: updatedAt)
    }

    private static func subscriptionURL(baseURL: URL) -> URL {
        var url = baseURL
        let pathComponents = url.path.split(separator: "/")
        if pathComponents.last == "v1" {
            url.append(path: "user/subscription")
        } else {
            url.append(path: "v1/user/subscription")
        }
        return url
    }
}
