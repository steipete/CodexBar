import Foundation

#if os(macOS)
import Security

// MARK: - Factory Token Importer

/// Imports Factory refresh tokens from Chrome localStorage (LevelDB)
public enum FactoryTokenImporter {
    private static let workosClientID = "client_01HNM792M5G5G1A2THWPXKFMXB"

    public struct TokenInfo: Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let email: String?
        public let sourceLabel: String

        public init(accessToken: String, refreshToken: String, email: String?, sourceLabel: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.email = email
            self.sourceLabel = sourceLabel
        }
    }

    /// Attempts to import Factory refresh token and exchange for access token
    public static func importSession(logger: ((String) -> Void)? = nil) async throws -> TokenInfo {
        // Try stored refresh token first (most likely to be valid)
        let storedToken = await FactorySessionStore.shared.getRefreshToken()
        if let storedToken, !storedToken.isEmpty {
            do {
                return try await Self.exchangeRefreshToken(storedToken, source: "Stored", logger: logger)
            } catch {
                await FactorySessionStore.shared.clearSession()
            }
        }

        // Try Chrome - read all tokens from localStorage and try each until one works
        let chromeTokens = (try? Self.readAllChromeRefreshTokens()) ?? []

        for token in chromeTokens {
            do {
                return try await Self.exchangeRefreshToken(token, source: "Chrome", logger: logger)
            } catch {
                continue
            }
        }

        throw FactoryStatusProbeError.noSessionCookie
    }

    private static func readAllChromeRefreshTokens() throws -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let chromePath = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Local Storage/leveldb")

        guard fm.fileExists(atPath: chromePath.path) else { return [] }

        var foundTokens: [String] = []
        var seenTokens: Set<String> = []

        // Read .ldb and .log files, sorted by modification date (newest first)
        let contents = (try? fm.contentsOfDirectory(at: chromePath, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return date1 > date2
            } ?? []

        for file in contents {
            let ext = file.pathExtension
            guard ext == "ldb" || ext == "log" else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }

            let content = String(decoding: data, as: UTF8.self)
            guard content.contains("app.factory.ai") else { continue }

            // Find tokens after "workos:refresh-token" marker
            let marker = "workos:refresh-token"
            var searchStart = content.startIndex

            while let markerRange = content.range(of: marker, range: searchStart..<content.endIndex) {
                searchStart = markerRange.upperBound

                // Skip non-alphanumeric characters
                var tokenStart = markerRange.upperBound
                while tokenStart < content.endIndex && !content[tokenStart].isLetter && !content[tokenStart].isNumber {
                    tokenStart = content.index(after: tokenStart)
                }

                // Read alphanumeric token
                var tokenEnd = tokenStart
                while tokenEnd < content.endIndex && (content[tokenEnd].isLetter || content[tokenEnd].isNumber) {
                    tokenEnd = content.index(after: tokenEnd)
                }

                let token = String(content[tokenStart..<tokenEnd])
                if token.count >= 20 && token.count <= 35 && !seenTokens.contains(token) {
                    seenTokens.insert(token)
                    foundTokens.append(token)
                }
            }
        }

        return foundTokens
    }

    private static func exchangeRefreshToken(
        _ refreshToken: String,
        source: String,
        logger: ((String) -> Void)? = nil) async throws -> TokenInfo
    {
        let url = URL(string: "https://api.workos.com/user_management/authenticate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "client_id": Self.workosClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid response from WorkOS")
        }

        guard httpResponse.statusCode == 200 else {
            throw FactoryStatusProbeError.notLoggedIn
        }

        struct WorkOSResponse: Codable {
            let access_token: String
            let refresh_token: String
            let user: WorkOSUser?
        }

        struct WorkOSUser: Codable {
            let email: String?
        }

        let workosResponse = try JSONDecoder().decode(WorkOSResponse.self, from: data)

        // Store the new refresh token for future use (WorkOS tokens are single-use)
        await FactorySessionStore.shared.setRefreshToken(workosResponse.refresh_token)

        return TokenInfo(
            accessToken: workosResponse.access_token,
            refreshToken: workosResponse.refresh_token,
            email: workosResponse.user?.email,
            sourceLabel: source)
    }

    /// Check if Factory session is available
    public static func hasSession(logger: ((String) -> Void)? = nil) async -> Bool {
        do {
            _ = try await Self.importSession(logger: logger)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Factory API Models

public struct FactoryAuthResponse: Codable, Sendable {
    public let featureFlags: FactoryFeatureFlags?
    public let organization: FactoryOrganization?
}

public struct FactoryFeatureFlags: Codable, Sendable {
    public let flags: [String: Bool]?
    public let configs: [String: AnyCodable]?
}

public struct FactoryOrganization: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let subscription: FactorySubscription?
}

public struct FactorySubscription: Codable, Sendable {
    public let factoryTier: String?
    public let orbSubscription: FactoryOrbSubscription?
}

public struct FactoryOrbSubscription: Codable, Sendable {
    public let plan: FactoryPlan?
    public let status: String?
}

public struct FactoryPlan: Codable, Sendable {
    public let name: String?
    public let id: String?
}

public struct FactoryUsageResponse: Codable, Sendable {
    public let usage: FactoryUsageData?
    public let source: String?
    public let userId: String?
}

public struct FactoryUsageData: Codable, Sendable {
    public let startDate: Int64?
    public let endDate: Int64?
    public let standard: FactoryTokenUsage?
    public let premium: FactoryTokenUsage?
}

public struct FactoryTokenUsage: Codable, Sendable {
    public let userTokens: Int64?
    public let orgTotalTokensUsed: Int64?
    public let totalAllowance: Int64?
    public let usedRatio: Double?
    public let orgOverageUsed: Int64?
    public let basicAllowance: Int64?
    public let orgOverageLimit: Int64?
}

/// Helper for decoding arbitrary JSON
public struct AnyCodable: Codable, Sendable {
    public init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

// MARK: - Factory Status Snapshot

public struct FactoryStatusSnapshot: Sendable {
    public let standardUserTokens: Int64
    public let standardOrgTokens: Int64
    public let standardAllowance: Int64
    public let premiumUserTokens: Int64
    public let premiumOrgTokens: Int64
    public let premiumAllowance: Int64
    public let periodStart: Date?
    public let periodEnd: Date?
    public let planName: String?
    public let tier: String?
    public let organizationName: String?
    public let accountEmail: String?
    public let userId: String?

    public init(
        standardUserTokens: Int64,
        standardOrgTokens: Int64,
        standardAllowance: Int64,
        premiumUserTokens: Int64,
        premiumOrgTokens: Int64,
        premiumAllowance: Int64,
        periodStart: Date?,
        periodEnd: Date?,
        planName: String?,
        tier: String?,
        organizationName: String?,
        accountEmail: String?,
        userId: String?)
    {
        self.standardUserTokens = standardUserTokens
        self.standardOrgTokens = standardOrgTokens
        self.standardAllowance = standardAllowance
        self.premiumUserTokens = premiumUserTokens
        self.premiumOrgTokens = premiumOrgTokens
        self.premiumAllowance = premiumAllowance
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.planName = planName
        self.tier = tier
        self.organizationName = organizationName
        self.accountEmail = accountEmail
        self.userId = userId
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let standardPercent = self.calculateUsagePercent(
            used: self.standardUserTokens,
            allowance: self.standardAllowance)

        let primary = RateWindow(
            usedPercent: standardPercent,
            windowMinutes: nil,
            resetsAt: self.periodEnd,
            resetDescription: self.periodEnd.map { Self.formatResetDate($0) })

        let premiumPercent = self.calculateUsagePercent(
            used: self.premiumUserTokens,
            allowance: self.premiumAllowance)

        let secondary = RateWindow(
            usedPercent: premiumPercent,
            windowMinutes: nil,
            resetsAt: self.periodEnd,
            resetDescription: self.periodEnd.map { Self.formatResetDate($0) })

        let loginMethod: String? = {
            var parts: [String] = []
            if let tier = self.tier, !tier.isEmpty {
                parts.append("Factory \(tier.capitalized)")
            }
            if let plan = self.planName, !plan.isEmpty, !plan.lowercased().contains("factory") {
                parts.append(plan)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " - ")
        }()

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: self.accountEmail,
            accountOrganization: self.organizationName,
            loginMethod: loginMethod)
    }

    private func calculateUsagePercent(used: Int64, allowance: Int64) -> Double {
        let unlimitedThreshold: Int64 = 1_000_000_000_000
        if allowance > unlimitedThreshold {
            let referenceTokens: Double = 100_000_000
            return min(100, Double(used) / referenceTokens * 100)
        }
        guard allowance > 0 else { return 0 }
        return min(100, Double(used) / Double(allowance) * 100)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Resets " + formatter.string(from: date)
    }
}

// MARK: - Factory Status Probe Error

public enum FactoryStatusProbeError: LocalizedError, Sendable {
    case notLoggedIn
    case networkError(String)
    case parseFailed(String)
    case noSessionCookie

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Factory. Please log in via the CodexBar menu."
        case let .networkError(msg):
            "Factory API error: \(msg)"
        case let .parseFailed(msg):
            "Could not parse Factory usage: \(msg)"
        case .noSessionCookie:
            "No Factory session found. Please log in to app.factory.ai in Safari, Chrome, or Firefox."
        }
    }
}

// MARK: - Factory Session Store

public actor FactorySessionStore {
    public static let shared = FactorySessionStore()

    private static let log = CodexBarLog.logger("factory-session")
    private static let keychainService = "com.steipete.CodexBar"
    private static let keychainAccount = "factory-refresh-token"

    private var refreshToken: String?
    private let legacyFileURL: URL

    private init() {
        self.legacyFileURL = Self.legacySessionFileURL()
        Task { await self.loadSession() }
    }

    public func setRefreshToken(_ token: String?) {
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshToken = cleaned
        self.saveToKeychain(cleaned)
        try? FileManager.default.removeItem(at: self.legacyFileURL)
    }

    public func getRefreshToken() -> String? {
        self.refreshToken
    }

    public func clearSession() {
        self.refreshToken = nil
        self.saveToKeychain(nil)
        try? FileManager.default.removeItem(at: self.legacyFileURL)
    }

    public func hasValidSession() -> Bool {
        self.refreshToken != nil && !self.refreshToken!.isEmpty
    }

    private func loadSession() {
        do {
            if let token = try Self.loadRefreshTokenFromKeychain() {
                self.refreshToken = token
                return
            }
        } catch {
            Self.log.error("Keychain read failed: \(error.localizedDescription)")
        }

        self.migrateLegacyFileIfPresent()
    }

    private func migrateLegacyFileIfPresent() {
        guard let data = try? Data(contentsOf: self.legacyFileURL) else { return }
        defer { try? FileManager.default.removeItem(at: self.legacyFileURL) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = json["refreshToken"],
              !token.isEmpty
        else { return }
        self.refreshToken = token
        self.saveToKeychain(token)
    }

    private func saveToKeychain(_ token: String?) {
        do {
            try Self.storeRefreshTokenInKeychain(token)
        } catch {
            Self.log.error("Keychain write failed: \(error.localizedDescription)")
        }
    }

    private static func legacySessionFileURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CodexBar", isDirectory: true)
        return dir.appendingPathComponent("factory-session.json")
    }

    private static func loadRefreshTokenFromKeychain() throws -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw FactorySessionStoreError.keychainStatus(status)
        }

        guard let data = result as? Data else {
            throw FactorySessionStoreError.invalidData
        }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            return token
        }
        return nil
    }

    private static func storeRefreshTokenInKeychain(_ token: String?) throws {
        let cleaned = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == nil || cleaned?.isEmpty == true {
            try self.deleteRefreshTokenFromKeychainIfPresent()
            return
        }

        let data = cleaned!.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw FactorySessionStoreError.keychainStatus(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw FactorySessionStoreError.keychainStatus(addStatus)
        }
    }

    private static func deleteRefreshTokenFromKeychainIfPresent() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw FactorySessionStoreError.keychainStatus(status)
    }
}

private enum FactorySessionStoreError: LocalizedError {
    case keychainStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .keychainStatus(status):
            "Keychain error: \(status)"
        case .invalidData:
            "Keychain returned invalid data."
        }
    }
}

// MARK: - Factory Status Probe

public struct FactoryStatusProbe: Sendable {
    public let baseURL: URL
    public var timeout: TimeInterval = 15.0

    public init(baseURL: URL = URL(string: "https://app.factory.ai")!, timeout: TimeInterval = 15.0) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot {
        let tokenInfo = try await FactoryTokenImporter.importSession(logger: logger)
        return try await self.fetchWithBearerToken(tokenInfo.accessToken, email: tokenInfo.email)
    }

    private func fetchWithBearerToken(_ bearerToken: String, email: String?) async throws -> FactoryStatusSnapshot {
        let authInfo = try await self.fetchAuthInfo(bearerToken: bearerToken)
        let usageData = try await self.fetchUsage(bearerToken: bearerToken)

        return self.buildSnapshot(authInfo: authInfo, usageData: usageData, email: email)
    }

    private func fetchAuthInfo(bearerToken: String) async throws -> FactoryAuthResponse {
        let url = self.baseURL.appendingPathComponent("/api/app/auth/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw FactoryStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw FactoryStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(FactoryAuthResponse.self, from: data)
        } catch {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw FactoryStatusProbeError
                .parseFailed("Auth decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func fetchUsage(bearerToken: String) async throws -> FactoryUsageResponse {
        let url = self.baseURL.appendingPathComponent("/api/organization/subscription/usage")
        var request = URLRequest(url: url)
        request.timeoutInterval = self.timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")

        let body: [String: Any] = ["useCache": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FactoryStatusProbeError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw FactoryStatusProbeError.notLoggedIn
        }

        guard httpResponse.statusCode == 200 else {
            throw FactoryStatusProbeError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(FactoryUsageResponse.self, from: data)
        } catch {
            let rawJSON = String(data: data, encoding: .utf8) ?? "<binary>"
            throw FactoryStatusProbeError
                .parseFailed("Usage decode failed: \(error.localizedDescription). Raw: \(rawJSON.prefix(200))")
        }
    }

    private func buildSnapshot(
        authInfo: FactoryAuthResponse,
        usageData: FactoryUsageResponse,
        email: String?) -> FactoryStatusSnapshot
    {
        let usage = usageData.usage

        let periodStart: Date? = usage?.startDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let periodEnd: Date? = usage?.endDate.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }

        return FactoryStatusSnapshot(
            standardUserTokens: usage?.standard?.userTokens ?? 0,
            standardOrgTokens: usage?.standard?.orgTotalTokensUsed ?? 0,
            standardAllowance: usage?.standard?.totalAllowance ?? 0,
            premiumUserTokens: usage?.premium?.userTokens ?? 0,
            premiumOrgTokens: usage?.premium?.orgTotalTokensUsed ?? 0,
            premiumAllowance: usage?.premium?.totalAllowance ?? 0,
            periodStart: periodStart,
            periodEnd: periodEnd,
            planName: authInfo.organization?.subscription?.orbSubscription?.plan?.name,
            tier: authInfo.organization?.subscription?.factoryTier,
            organizationName: authInfo.organization?.name,
            accountEmail: email,
            userId: usageData.userId)
    }
}

#else

// MARK: - Factory (Unsupported Platforms)

public enum FactoryStatusProbeError: LocalizedError, Sendable {
    case notSupported

    public var errorDescription: String? {
        "Factory is only supported on macOS."
    }
}

public struct FactoryStatusSnapshot: Sendable {
    public init() {}

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: nil)
    }
}

public struct FactoryStatusProbe: Sendable {
    public init(baseURL: URL = URL(string: "https://app.factory.ai")!, timeout: TimeInterval = 15.0) {}

    public func fetch(logger: ((String) -> Void)? = nil) async throws -> FactoryStatusSnapshot {
        throw FactoryStatusProbeError.notSupported
    }
}

#endif
