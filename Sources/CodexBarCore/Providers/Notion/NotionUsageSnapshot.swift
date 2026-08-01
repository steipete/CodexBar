import Foundation

public enum NotionUsageError: LocalizedError, Sendable, Equatable {
    case noSessionCookie
    case cookieImportDeferred
    case invalidCredentials
    case noWorkspace
    case allowanceNotApplicable(workspace: String?)
    case apiError(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            "No Notion cookies found. Please log in to notion.com in your browser."
        case .cookieImportDeferred:
            "Notion cookies can only be read during a manual refresh. Refresh CodexBar once to import them."
        case .invalidCredentials:
            "Notion session cookie is invalid or expired."
        case .noWorkspace:
            "No Notion workspace found for this account."
        case let .allowanceNotApplicable(workspace):
            if let workspace {
                "Notion AI usage allowance is not tracked for \"\(workspace)\". " +
                    "Allowances apply to Business and Enterprise workspaces."
            } else {
                "Notion AI usage allowance is not tracked for this workspace. " +
                    "Allowances apply to Business and Enterprise workspaces."
            }
        case let .apiError(message):
            "Notion API error: \(message)"
        case let .parseFailed(message):
            "Could not parse Notion usage: \(message)"
        }
    }
}

// MARK: - Account

/// One workspace ("space") the signed-in account belongs to.
public struct NotionWorkspace: Sendable, Equatable {
    public let id: String
    public let name: String?
    public let planType: String?
    public let subscriptionTier: String?

    public init(id: String, name: String?, planType: String?, subscriptionTier: String?) {
        self.id = id
        self.name = name
        self.planType = planType
        self.subscriptionTier = subscriptionTier
    }

    /// Only paid team plans carry a Notion AI usage allowance; free/personal spaces report `not_applicable`.
    public var mayHaveAllowance: Bool {
        switch self.subscriptionTier?.lowercased() {
        case "business", "enterprise": true
        default: false
        }
    }

    public var displayTier: String? {
        guard let raw = self.subscriptionTier?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

public struct NotionAccount: Sendable, Equatable {
    public let userID: String?
    public let email: String?
    public let name: String?
    public let workspaces: [NotionWorkspace]

    public init(userID: String?, email: String?, name: String?, workspaces: [NotionWorkspace]) {
        self.userID = userID
        self.email = email
        self.name = name
        self.workspaces = workspaces
    }

    /// Picks the workspace whose allowance we report: an explicit id when configured, otherwise the first
    /// workspace on a plan that actually has an allowance, otherwise the first workspace at all.
    public func resolveWorkspace(preferredID: String? = nil) -> NotionWorkspace? {
        if let preferredID = Self.normalizeSpaceID(preferredID),
           let match = self.workspaces.first(where: { Self.normalizeSpaceID($0.id) == preferredID })
        {
            return match
        }
        // A configured id the account cannot see is almost always a typo. Querying it anyway only
        // yields an opaque 403, so fall back to the workspace auto-selection would have picked.
        return self.workspaces.first(where: \.mayHaveAllowance) ?? self.workspaces.first
    }

    /// Notion accepts both dashed and undashed space ids; normalize to the dashed form the API returns.
    static func normalizeSpaceID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let compact = trimmed.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.count == 32, compact.allSatisfy(\.isHexDigit) else { return trimmed.lowercased() }
        let chars = Array(compact)
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        return groups.map { String(chars[$0]) }.joined(separator: "-")
    }
}

// MARK: - Rate limit payload

public struct NotionRollingWindow: Decodable, Sendable, Equatable {
    public let creditType: String?
    public let scope: String?
    public let window: String?
    public let used: Double?
    public let limit: Double?
}

public struct NotionBillingPeriodWindow: Decodable, Sendable, Equatable {
    public let creditType: String?
    public let scope: String?
    public let cadence: String?
    public let used: Double?
    public let limit: Double?
    public let periodEndMs: Double?
}

/// Response of `POST /api/v3/getCreditRateLimitStatus`.
public struct NotionCreditRateLimitStatus: Decodable, Sendable, Equatable {
    public let status: String?
    public let window: NotionRollingWindow?
    public let resetsInSeconds: Double?
    public let billingPeriodWindow: NotionBillingPeriodWindow?
    public let enforcement: String?

    /// Notion returns this when the workspace plan has no allowance to report.
    public var isNotApplicable: Bool {
        self.status?.lowercased() == "not_applicable"
    }
}

// MARK: - Snapshot

public struct NotionUsageSnapshot: Sendable {
    public let rateLimit: NotionCreditRateLimitStatus
    public let workspace: NotionWorkspace?
    public let account: NotionAccount?
    public let updatedAt: Date

    public init(
        rateLimit: NotionCreditRateLimitStatus,
        workspace: NotionWorkspace?,
        account: NotionAccount?,
        updatedAt: Date)
    {
        self.rateLimit = rateLimit
        self.workspace = workspace
        self.account = account
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        // Only report a window we could actually measure. Fabricating 0% for a missing or
        // unmeasurable window reads as "plenty of headroom" on a workspace that may be at its cap.
        let primary: RateWindow? = self.rateLimit.window.flatMap { window in
            Self.percent(used: window.used, limit: window.limit).map { percent in
                RateWindow(
                    usedPercent: percent,
                    windowMinutes: Self.minutes(fromWindowToken: window.window),
                    resetsAt: Self.rollingReset(from: self.rateLimit.resetsInSeconds, now: self.updatedAt),
                    resetDescription: nil)
            }
        }

        let secondary: RateWindow? = self.rateLimit.billingPeriodWindow.flatMap { billing in
            Self.percent(used: billing.used, limit: billing.limit).map { percent in
                RateWindow(
                    usedPercent: percent,
                    windowMinutes: nil,
                    resetsAt: Self.date(fromMilliseconds: billing.periodEndMs),
                    resetDescription: nil)
            }
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .notion,
            accountEmail: self.account?.email,
            accountOrganization: self.workspace?.name,
            loginMethod: self.workspace?.displayTier,
            accountID: self.account?.userID)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: self.updatedAt,
            identity: identity)
    }

    /// Returns nil when the window carries no measurable allowance. A missing or non-positive limit
    /// means "nothing to measure against", not "usage happens to equal this percentage" — the raw
    /// credit count is on a different scale and would render as a wildly wrong gauge.
    static func percent(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        return max(0, used / limit * 100)
    }

    /// Notion expresses the rolling window as a short token such as `6h`.
    static func minutes(fromWindowToken raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        guard let unit = raw.last, let value = Int(raw.dropLast()), value > 0 else { return nil }
        switch unit {
        case "m": return value
        case "h": return value * 60
        case "d": return value * 24 * 60
        case "w": return value * 7 * 24 * 60
        default: return nil
        }
    }

    /// Zero is a real answer — the window is resetting right now — so only negative values are dropped.
    static func rollingReset(from seconds: Double?, now: Date) -> Date? {
        guard let seconds, seconds >= 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    static func date(fromMilliseconds raw: Double?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw / 1000)
    }
}

// MARK: - Parsing

public enum NotionUsageParser {
    public static func parseRateLimitStatus(_ data: Data) throws -> NotionCreditRateLimitStatus {
        let status: NotionCreditRateLimitStatus
        do {
            status = try JSONDecoder().decode(NotionCreditRateLimitStatus.self, from: data)
        } catch {
            throw NotionUsageError.parseFailed(error.localizedDescription)
        }
        // Every field is optional, so an unrelated 200 body (an error envelope, or a changed shape)
        // decodes cleanly into an all-nil status. Refuse it rather than reporting it as 0% used.
        guard status.isNotApplicable || status.window != nil || status.billingPeriodWindow != nil else {
            throw NotionUsageError.parseFailed("getCreditRateLimitStatus returned no usage windows.")
        }
        return status
    }

    /// Parses `POST /api/v3/getSpaces`, which returns record maps keyed by user id and space id.
    public static func parseSpaces(_ data: Data) throws -> NotionAccount {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionUsageError.parseFailed("getSpaces response is not a JSON object.")
        }
        guard let userID = Self.resolveUserID(in: root), let container = root[userID] as? [String: Any] else {
            throw NotionUsageError.parseFailed("getSpaces response did not identify a single user.")
        }

        var email: String?
        var name: String?
        if let users = container["notion_user"] as? [String: Any] {
            let record = users[userID].flatMap(Self.unwrapRecord) ?? users.values.compactMap(Self.unwrapRecord).first
            email = record?["email"] as? String
            name = record?["name"] as? String
        }

        var workspaces: [NotionWorkspace] = []
        if let spaces = container["space"] as? [String: Any] {
            for key in spaces.keys.sorted() {
                guard let record = spaces[key].flatMap(Self.unwrapRecord) else { continue }
                workspaces.append(NotionWorkspace(
                    id: (record["id"] as? String) ?? key,
                    name: record["name"] as? String,
                    planType: record["plan_type"] as? String,
                    subscriptionTier: record["subscription_tier"] as? String))
            }
        }

        return NotionAccount(userID: userID, email: email, name: name, workspaces: workspaces)
    }

    /// The payload is a record map keyed by user id. Pick the key whose own `notion_user` record
    /// identifies it, rather than trusting key order, and refuse an ambiguous response outright —
    /// binding to the wrong key would report another account's allowance under this account's email.
    private static func resolveUserID(in root: [String: Any]) -> String? {
        let identified = root.keys.filter { key in
            guard let container = root[key] as? [String: Any],
                  let users = container["notion_user"] as? [String: Any],
                  let record = users[key].flatMap(Self.unwrapRecord)
            else {
                return false
            }
            return record["id"] as? String == key
        }
        if identified.count == 1 { return identified.first }
        // Older responses omit the self-identifying id; a single-key payload is still unambiguous.
        if identified.isEmpty, root.count == 1 { return root.keys.first }
        return nil
    }

    /// Records arrive as `{"value": {...}}` or, on newer responses, `{"value": {"value": {...}}}`.
    private static func unwrapRecord(_ raw: Any) -> [String: Any]? {
        guard let outer = raw as? [String: Any] else { return nil }
        guard let value = outer["value"] as? [String: Any] else { return outer }
        if let inner = value["value"] as? [String: Any] { return inner }
        return value
    }
}
