import Foundation
import SQLite3
#if canImport(Darwin)
import Darwin
#endif

/// Direct API fetch strategy for Kiro usage that bypasses `kiro-cli` and calls
/// the AWS Q `getUsageLimits` REST endpoint directly.
///
/// This fixes enterprise/IdC account usage fetching where `kiro-cli` fails because
/// it incorrectly passes `profileArn` to the legacy REST API, causing a 400 error.
/// The Kiro 0.9.2 version of these APIs does NOT accept `profileArn`.
///
/// Reference: https://github.com/ZyphrZero/kiro.rs (v0.6.11 fix)
struct KiroAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "kiro.api"
    let kind: ProviderFetchKind = .apiToken

    /// Fixed Kiro IDE version for usage REST APIs.
    /// This version does not require `profileArn`, which is the key fix for enterprise accounts.
    private static let usageAPIKiroVersion = "0.9.2"

    /// AWS Q REST API regions (only these two serve getUsageLimits)
    private static let apiRegions = ["us-east-1", "eu-central-1"]

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        Self.resolveCredentials() != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let credentials = Self.resolveCredentials() else {
            throw KiroAPIError.credentialsNotFound
        }

        let snapshot = try await Self.fetchUsage(credentials: credentials)
        return self.makeResult(
            usage: snapshot.toUsageSnapshot(),
            sourceLabel: "api")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // Only fall back to CLI in auto mode
        context.sourceMode == .auto
    }

    // MARK: - Credential Resolution

    /// Credential keys to try, in order of preference
    private static let credentialKeys = [
        "kirocli:odic:token",   // Current (typo in kiro-cli, kept for compat)
        "kirocli:oidc:token",   // Correct spelling, newer versions
        "kirocli:social:token", // Social login (GitHub/Google)
    ]

    /// Read credentials from kiro-cli's SQLite database
    private static func resolveCredentials() -> KiroCLICredentials? {
        let dbPath = NSString(string: "~/Library/Application Support/kiro-cli/data.sqlite3")
            .expandingTildeInPath

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return nil
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // Try each credential key until we find one with a valid token
        for key in credentialKeys {
            if let creds = queryCredentials(db: db, key: key) {
                return creds
            }
        }

        return nil
    }

    private static func queryCredentials(db: OpaquePointer?, key: String) -> KiroCLICredentials? {
        guard let db else { return nil }
        let query = "SELECT value FROM auth_kv WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = sqlite3_column_text(stmt, 0)
        else {
            return nil
        }

        let jsonString = String(cString: blob)
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty
        else {
            return nil
        }

        let region = json["region"] as? String
        let startURL = json["start_url"] as? String

        return KiroCLICredentials(
            accessToken: accessToken,
            region: region,
            startURL: startURL)
    }

    // MARK: - API Fetch

    /// Fetch usage directly from AWS Q API (no profileArn, fixed Kiro version)
    private static func fetchUsage(credentials: KiroCLICredentials) async throws -> KiroUsageSnapshot {
        let regions = regionCandidates(for: credentials.region)

        var lastError: Error?
        for region in regions {
            do {
                return try await fetchUsageFromRegion(
                    region: region,
                    accessToken: credentials.accessToken,
                    startURL: credentials.startURL)
            } catch let error as URLError where error.code == .badServerResponse {
                lastError = error
                continue
            } catch {
                throw error
            }
        }

        throw lastError ?? KiroAPIError.allRegionsFailed
    }

    private static func fetchUsageFromRegion(
        region: String,
        accessToken: String,
        startURL: String?) async throws -> KiroUsageSnapshot
    {
        let host = "q.\(region).amazonaws.com"
        let urlString = "https://\(host)/getUsageLimits?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST&isEmailRequired=true"

        guard let url = URL(string: urlString) else {
            throw KiroAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Machine ID (simplified - use a stable identifier)
        let machineId = generateMachineId()

        // User-Agent matching Kiro 0.9.2 (the version that doesn't require profileArn)
        let userAgent = "aws-sdk-js/1.0.0 ua/2.1 os/macos lang/js md/nodejs#20.0.0 api/codewhispererruntime#1.0.0 m/N,E KiroIDE-\(usageAPIKiroVersion)-\(machineId)"
        let amzUserAgent = "aws-sdk-js/1.0.0 KiroIDE-\(usageAPIKiroVersion)-\(machineId)"

        request.setValue(amzUserAgent, forHTTPHeaderField: "x-amz-user-agent")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue(host, forHTTPHeaderField: "host")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "amz-sdk-invocation-id")
        request.setValue("attempt=1; max=1", forHTTPHeaderField: "amz-sdk-request")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("close", forHTTPHeaderField: "Connection")

        // For enterprise/IdC accounts, we need to detect the auth method.
        // If startURL is present, it's likely an enterprise account.
        // However, we do NOT pass profileArn - that's the key fix.
        if let startURL, !startURL.isEmpty {
            // Enterprise accounts may need EXTERNAL_IDP token type
            // But we don't have enough info here to determine the exact type
            // The API should work without it for usage endpoints
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KiroAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let usageResponse = try decoder.decode(KiroUsageLimitsResponse.self, from: data)
            return try usageResponse.toSnapshot()
        case 403:
            // Try next region
            throw URLError(.badServerResponse)
        case 401:
            throw KiroAPIError.authenticationFailed
        case 429:
            throw KiroAPIError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw KiroAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    /// Region candidate ordering: prefer us-east-1, fallback to eu-central-1
    private static func regionCandidates(for ssoRegion: String?) -> [String] {
        guard let ssoRegion else { return apiRegions }
        if ssoRegion == "eu-central-1" || ssoRegion.hasPrefix("eu-") {
            return ["eu-central-1", "us-east-1"]
        }
        return apiRegions
    }

    /// Generate a stable machine ID from the device's hardware UUID
    private static func generateMachineId() -> String {
        #if canImport(Darwin)
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }

        guard platformExpert != 0,
              let uuidCF = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  kIOPlatformUUIDKey as CFString,
                  kCFAllocatorDefault, 0)
        else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        let uuid = uuidCF.takeRetainedValue() as? String ?? UUID().uuidString
        return uuid.replacingOccurrences(of: "-", with: "")
        #else
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        #endif
    }
}

// MARK: - Supporting Types

private struct KiroCLICredentials {
    let accessToken: String
    let region: String?
    let startURL: String?
}

enum KiroAPIError: Error, LocalizedError {
    case credentialsNotFound
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case rateLimited
    case allRegionsFailed
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Kiro credentials not found. Please run 'kiro-cli login' first."
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from Kiro API"
        case .authenticationFailed:
            return "Kiro authentication failed. Please run 'kiro-cli login' again."
        case .rateLimited:
            return "Kiro API rate limited. Please try again later."
        case .allRegionsFailed:
            return "All Kiro API regions failed"
        case .httpError(let statusCode, let body):
            return "Kiro API error: \(statusCode) \(body)"
        }
    }
}

// MARK: - API Response Models

struct KiroUsageLimitsResponse: Decodable {
    let nextDateReset: Double?
    let subscriptionInfo: KiroSubscriptionInfo?
    let usageBreakdownList: [KiroUsageBreakdown]?
    let overageConfiguration: KiroOverageConfiguration?
    let userInfo: KiroUserInfo?

    enum CodingKeys: String, CodingKey {
        case nextDateReset
        case subscriptionInfo
        case usageBreakdownList
        case overageConfiguration
        case userInfo
    }

    func toSnapshot() throws -> KiroUsageSnapshot {
        let planName = subscriptionInfo?.subscriptionTitle ?? "KIRO FREE"
        let email = userInfo?.email

        guard let breakdown = usageBreakdownList?.first else {
            // No usage data - might be a managed/enterprise plan
            return KiroUsageSnapshot(
                planName: planName,
                displayPlanName: KiroStatusProbe.displayPlanName(planName),
                accountEmail: email,
                authMethod: nil,
                creditsUsed: 0,
                creditsTotal: 0,
                creditsPercent: 0,
                bonusCreditsUsed: nil,
                bonusCreditsTotal: nil,
                bonusExpiryDays: nil,
                overagesStatus: overageConfiguration?.overageStatus,
                overageCreditsUsed: nil,
                estimatedOverageCostUSD: nil,
                manageURL: nil,
                contextUsage: nil,
                resetsAt: nextDateReset.map { Date(timeIntervalSince1970: $0) },
                updatedAt: Date())
        }

        let creditsUsed = breakdown.currentUsageWithPrecision ?? Double(breakdown.currentUsage ?? 0)
        let creditsTotal = breakdown.usageLimitWithPrecision ?? Double(breakdown.usageLimit ?? 0)
        let creditsPercent = creditsTotal > 0 ? (creditsUsed / creditsTotal) * 100.0 : 0

        // Calculate bonus credits
        var bonusUsed: Double?
        var bonusTotal: Double?
        var bonusExpiry: Int?

        let activeBonuses = (breakdown.bonuses ?? []).filter { $0.status == "ACTIVE" }
        if !activeBonuses.isEmpty {
            bonusUsed = activeBonuses.reduce(0) { $0 + ($1.currentUsage ?? 0) }
            bonusTotal = activeBonuses.reduce(0) { $0 + ($1.usageLimit ?? 0) }
        }

        // Overages
        let overageEnabled = overageConfiguration?.overageEnabled ?? false
        let overagesStatus = overageConfiguration?.overageStatus

        return KiroUsageSnapshot(
            planName: planName,
            displayPlanName: KiroStatusProbe.displayPlanName(planName),
            accountEmail: email,
            authMethod: nil,
            creditsUsed: creditsUsed,
            creditsTotal: creditsTotal,
            creditsPercent: creditsPercent,
            bonusCreditsUsed: bonusUsed,
            bonusCreditsTotal: bonusTotal,
            bonusExpiryDays: bonusExpiry,
            overagesStatus: overagesStatus,
            overageCreditsUsed: nil,
            estimatedOverageCostUSD: nil,
            manageURL: nil,
            contextUsage: nil,
            resetsAt: nextDateReset.map { Date(timeIntervalSince1970: $0) },
            updatedAt: Date())
    }
}

struct KiroSubscriptionInfo: Decodable {
    let subscriptionTitle: String?
    let overageCapability: String?
}

struct KiroUsageBreakdown: Decodable {
    let currentUsage: Int?
    let currentUsageWithPrecision: Double?
    let usageLimit: Int?
    let usageLimitWithPrecision: Double?
    let bonuses: [KiroBonus]?
    let freeTrialInfo: KiroFreeTrialInfo?

    enum CodingKeys: String, CodingKey {
        case currentUsage
        case currentUsageWithPrecision
        case usageLimit
        case usageLimitWithPrecision
        case bonuses
        case freeTrialInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentUsage = try container.decodeIfPresent(Int.self, forKey: .currentUsage)
        currentUsageWithPrecision = try container.decodeIfPresent(Double.self, forKey: .currentUsageWithPrecision)
        usageLimit = try container.decodeIfPresent(Int.self, forKey: .usageLimit)
        usageLimitWithPrecision = try container.decodeIfPresent(Double.self, forKey: .usageLimitWithPrecision)
        bonuses = try container.decodeIfPresent([KiroBonus].self, forKey: .bonuses)
        freeTrialInfo = try container.decodeIfPresent(KiroFreeTrialInfo.self, forKey: .freeTrialInfo)
    }
}

struct KiroBonus: Decodable {
    let currentUsage: Double?
    let usageLimit: Double?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case currentUsage
        case usageLimit
        case status
    }
}

struct KiroFreeTrialInfo: Decodable {
    let currentUsage: Int?
    let currentUsageWithPrecision: Double?
    let usageLimit: Int?
    let usageLimitWithPrecision: Double?
    let freeTrialExpiry: Double?
    let freeTrialStatus: String?

    enum CodingKeys: String, CodingKey {
        case currentUsage
        case currentUsageWithPrecision
        case usageLimit
        case usageLimitWithPrecision
        case freeTrialExpiry
        case freeTrialStatus
    }
}

struct KiroOverageConfiguration: Decodable {
    let overageEnabled: Bool?
    let overageStatus: String?
}

struct KiroUserInfo: Decodable {
    let email: String?
}
