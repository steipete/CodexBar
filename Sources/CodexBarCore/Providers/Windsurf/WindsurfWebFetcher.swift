import Foundation

// MARK: - API Response Model

public struct WindsurfGetPlanStatusResponse: Sendable, Equatable {
    public let planStatus: PlanStatus?

    public struct PlanStatus: Sendable, Equatable {
        public let planInfo: PlanInfo?
        public let planStart: Date?
        public let planEnd: Date?
        public let dailyQuotaRemainingPercent: Int?
        public let weeklyQuotaRemainingPercent: Int?
        public let dailyQuotaResetAtUnix: Int64?
        public let weeklyQuotaResetAtUnix: Int64?
        public let topUpStatus: TopUpStatus?
        public let gracePeriodStatus: Int?

        public struct PlanInfo: Sendable, Equatable {
            public let planName: String?
            public let teamsTier: Int?
        }

        public struct TopUpStatus: Sendable, Equatable {
            public let topUpTransactionStatus: Int?
        }
    }
}

// MARK: - Conversion to UsageSnapshot

extension WindsurfGetPlanStatusResponse {
    public func toUsageSnapshot() -> UsageSnapshot {
        var primary: RateWindow?
        var secondary: RateWindow?

        if let status = self.planStatus {
            if let daily = status.dailyQuotaRemainingPercent {
                let resetDate = status.dailyQuotaResetAtUnix.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                primary = RateWindow(
                    usedPercent: max(0, min(100, 100 - Double(daily))),
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: Self.formatResetDescription(resetDate))
            }

            if let weekly = status.weeklyQuotaRemainingPercent {
                let resetDate = status.weeklyQuotaResetAtUnix.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                secondary = RateWindow(
                    usedPercent: max(0, min(100, 100 - Double(weekly))),
                    windowMinutes: nil,
                    resetsAt: resetDate,
                    resetDescription: Self.formatResetDescription(resetDate))
            }
        }

        var orgDescription: String?
        if let endDate = self.planStatus?.planEnd {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            orgDescription = "Expires \(formatter.string(from: endDate))"
        }

        let identity = ProviderIdentitySnapshot(
            providerID: .windsurf,
            accountEmail: nil,
            accountOrganization: orgDescription,
            loginMethod: self.planStatus?.planInfo?.planName)

        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let now = Date()
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Expired" }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "Resets in \(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }
}

// MARK: - Session Material

#if os(macOS)

struct WindsurfDevinSessionAuth: Codable, Equatable {
    let sessionToken: String
    let auth1Token: String
    let accountID: String
    let primaryOrgID: String
}

public enum WindsurfWebFetcherError: LocalizedError, Sendable {
    case noSessionData
    case invalidManualSession(String)
    case apiCallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSessionData:
            "No Windsurf web session found in Chromium localStorage. Sign in to windsurf.com in Chrome or Edge first."
        case let .invalidManualSession(message):
            "Invalid Windsurf session payload: \(message)"
        case let .apiCallFailed(message):
            "Windsurf API call failed: \(message)"
        }
    }
}

public enum WindsurfWebFetcher {
    private static let windsurfOrigin = "https://windsurf.com"
    private static let windsurfProfileReferer = "https://windsurf.com/profile"
    private static let getPlanStatusURL = "https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetPlanStatus"

    public static func fetchUsage(
        browserDetection: BrowserDetection,
        cookieSource: ProviderCookieSource = .auto,
        manualSessionInput: String? = nil,
        timeout: TimeInterval = 15,
        logger: ((String) -> Void)? = nil,
        session: URLSession = .shared) async throws -> UsageSnapshot
    {
        let log: (String) -> Void = { msg in logger?("[windsurf-web] \(msg)") }

        if cookieSource == .manual {
            guard let manualSessionInput,
                  !manualSessionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw WindsurfWebFetcherError.invalidManualSession("empty input")
            }
            log("Using manual Windsurf session bundle")
            let auth = try self.parseManualSessionInput(manualSessionInput)
            let response = try await self.fetchPlanStatus(auth: auth, timeout: timeout, session: session)
            return response.toUsageSnapshot()
        }

        guard cookieSource != .off else {
            throw WindsurfWebFetcherError.noSessionData
        }

        let preferredSessionInfos = WindsurfDevinSessionImporter.importPreferredSessions(
            browserDetection: browserDetection,
            logger: logger)
        let sessionInfos = preferredSessionInfos.isEmpty
            ? WindsurfDevinSessionImporter.importFallbackSessions(
                browserDetection: browserDetection,
                logger: logger)
            : preferredSessionInfos
        guard !sessionInfos.isEmpty else {
            throw WindsurfWebFetcherError.noSessionData
        }

        do {
            return try await self.fetchUsage(
                sessionInfos: sessionInfos,
                timeout: timeout,
                logger: log,
                session: session)
        } catch {
            guard !preferredSessionInfos.isEmpty, self.isRecoverableImportedSessionError(error) else {
                throw error
            }
        }

        log("Chrome Windsurf sessions failed; trying fallback Chromium browser sessions")
        let fallbackSessionInfos = WindsurfDevinSessionImporter.importFallbackSessions(
            browserDetection: browserDetection,
            logger: logger)
        guard !fallbackSessionInfos.isEmpty else {
            throw WindsurfWebFetcherError.noSessionData
        }
        return try await self.fetchUsage(
            sessionInfos: fallbackSessionInfos,
            timeout: timeout,
            logger: log,
            session: session)
    }

    static func parseManualSessionInput(_ raw: String) throws -> WindsurfDevinSessionAuth {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WindsurfWebFetcherError.invalidManualSession("empty input")
        }

        if let auth = self.parseJSONSessionInput(trimmed) {
            return auth
        }

        if let auth = self.parseKeyValueSessionInput(trimmed) {
            return auth
        }

        throw WindsurfWebFetcherError.invalidManualSession(
            "expected JSON with devin_session_token, devin_auth1_token, devin_account_id, and devin_primary_org_id")
    }

    private static func parseJSONSessionInput(_ raw: String) -> WindsurfDevinSessionAuth? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return self.sessionAuth(from: json)
    }

    private static func parseKeyValueSessionInput(_ raw: String) -> WindsurfDevinSessionAuth? {
        let separators = CharacterSet(charactersIn: "\n,;")
        let segments = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var values: [String: String] = [:]
        for segment in segments {
            let delimiter: Character? = segment.contains("=") ? "=" : (segment.contains(":") ? ":" : nil)
            guard let delimiter, let index = segment.firstIndex(of: delimiter) else { continue }
            let key = String(segment[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(segment[segment.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        guard !values.isEmpty else { return nil }
        return self.sessionAuth(from: values)
    }

    private static func isRecoverableImportedSessionError(_ error: Error) -> Bool {
        guard case let WindsurfWebFetcherError.apiCallFailed(message) = error else {
            return false
        }

        return ["HTTP 400", "HTTP 401", "HTTP 403"].contains { message.hasPrefix($0) }
    }

    private static func fetchUsage(
        sessionInfos: [WindsurfDevinSessionImporter.SessionInfo],
        timeout: TimeInterval,
        logger log: (String) -> Void,
        session: URLSession) async throws -> UsageSnapshot
    {
        var lastError: Error?
        for sessionInfo in sessionInfos {
            do {
                log("Using devin session from \(sessionInfo.sourceLabel)")
                let response = try await self.fetchPlanStatus(
                    auth: sessionInfo.session,
                    timeout: timeout,
                    session: session)
                return response.toUsageSnapshot()
            } catch {
                guard self.isRecoverableImportedSessionError(error) else {
                    throw error
                }
                lastError = error
                log("Windsurf devin session from \(sessionInfo.sourceLabel) failed; trying next imported session")
            }
        }

        throw lastError ?? WindsurfWebFetcherError.noSessionData
    }

    private static func sessionAuth(from values: [String: Any]) -> WindsurfDevinSessionAuth? {
        func stringValue(for keys: [String]) -> String? {
            for key in keys {
                if let value = values[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
            return nil
        }

        guard let sessionToken = stringValue(for: ["devin_session_token", "devinSessionToken", "sessionToken"]),
              let auth1Token = stringValue(for: ["devin_auth1_token", "devinAuth1Token", "auth1Token"]),
              let accountID = stringValue(for: ["devin_account_id", "devinAccountId", "accountID", "accountId"]),
              let primaryOrgID = stringValue(for: [
                  "devin_primary_org_id",
                  "devinPrimaryOrgId",
                  "primaryOrgID",
                  "primaryOrgId",
              ])
        else {
            return nil
        }

        return WindsurfDevinSessionAuth(
            sessionToken: sessionToken,
            auth1Token: auth1Token,
            accountID: accountID,
            primaryOrgID: primaryOrgID)
    }

    private static func fetchPlanStatus(
        auth: WindsurfDevinSessionAuth,
        timeout: TimeInterval,
        session: URLSession) async throws -> WindsurfGetPlanStatusResponse
    {
        guard let url = URL(string: self.getPlanStatusURL) else {
            throw WindsurfWebFetcherError.apiCallFailed("Invalid GetPlanStatus URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        self.applyWindsurfHeaders(to: &request, auth: auth)
        request.httpBody = WindsurfPlanStatusProtoCodec.encodeRequest(
            authToken: auth.sessionToken,
            includeTopUpStatus: true)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WindsurfWebFetcherError.apiCallFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = if let body, !body.isEmpty {
                ": \(body.prefix(200))"
            } else {
                ": <binary \(data.count) bytes>"
            }
            throw WindsurfWebFetcherError.apiCallFailed("HTTP \(httpResponse.statusCode)\(snippet)")
        }

        do {
            return try WindsurfPlanStatusProtoCodec.decodeResponse(data)
        } catch {
            throw WindsurfWebFetcherError.apiCallFailed("Parse error: \(error.localizedDescription)")
        }
    }

    private static func applyWindsurfHeaders(to request: inout URLRequest, auth: WindsurfDevinSessionAuth) {
        request.setValue(self.windsurfOrigin, forHTTPHeaderField: "Origin")
        request.setValue(self.windsurfProfileReferer, forHTTPHeaderField: "Referer")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-auth-token")
        request.setValue(auth.sessionToken, forHTTPHeaderField: "x-devin-session-token")
        request.setValue(auth.auth1Token, forHTTPHeaderField: "x-devin-auth1-token")
        request.setValue(auth.accountID, forHTTPHeaderField: "x-devin-account-id")
        request.setValue(auth.primaryOrgID, forHTTPHeaderField: "x-devin-primary-org-id")
    }
}

enum WindsurfPlanStatusProtoCodec {
    /// Field numbers come from Windsurf's bundled protobuf metadata in
    /// `/Applications/Windsurf.app/.../extension.js` and were re-verified against live browser traffic on 2026-04-17.
    struct Request: Equatable {
        let authToken: String
        let includeTopUpStatus: Bool
    }

    static func encodeRequest(authToken: String, includeTopUpStatus: Bool) -> Data {
        var data = Data()
        self.appendFieldKey(1, wireType: .lengthDelimited, to: &data)
        self.appendString(authToken, to: &data)
        self.appendFieldKey(2, wireType: .varint, to: &data)
        self.appendVarint(includeTopUpStatus ? 1 : 0, to: &data)
        return data
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        var reader = ProtoReader(data: data)
        var authToken: String?
        var includeTopUpStatus = false

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                authToken = try reader.readString()
            case (2, .varint):
                includeTopUpStatus = try reader.readVarint() != 0
            default:
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }

        guard let authToken else {
            throw WindsurfProtoError.missingField("auth_token")
        }

        return Request(authToken: authToken, includeTopUpStatus: includeTopUpStatus)
    }

    static func decodeResponse(_ data: Data) throws -> WindsurfGetPlanStatusResponse {
        var reader = ProtoReader(data: data)
        var planStatus: WindsurfGetPlanStatusResponse.PlanStatus?

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                planStatus = try self.decodePlanStatus(from: reader.readLengthDelimitedData())
            default:
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }

        return WindsurfGetPlanStatusResponse(planStatus: planStatus)
    }

    private static func decodePlanStatus(from data: Data) throws -> WindsurfGetPlanStatusResponse.PlanStatus {
        var reader = ProtoReader(data: data)
        var planInfo: WindsurfGetPlanStatusResponse.PlanStatus.PlanInfo?
        var planStart: Date?
        var planEnd: Date?
        var dailyQuotaRemainingPercent: Int?
        var weeklyQuotaRemainingPercent: Int?
        var dailyQuotaResetAtUnix: Int64?
        var weeklyQuotaResetAtUnix: Int64?
        var topUpStatus: WindsurfGetPlanStatusResponse.PlanStatus.TopUpStatus?
        var gracePeriodStatus: Int?

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited):
                planInfo = try self.decodePlanInfo(from: reader.readLengthDelimitedData())
            case (2, .lengthDelimited):
                planStart = try self.decodeTimestamp(from: reader.readLengthDelimitedData())
            case (3, .lengthDelimited):
                planEnd = try self.decodeTimestamp(from: reader.readLengthDelimitedData())
            case (10, .lengthDelimited):
                topUpStatus = try self.decodeTopUpStatus(from: reader.readLengthDelimitedData())
            case (12, .varint):
                gracePeriodStatus = try Int(reader.readVarint())
            case (14, .varint):
                dailyQuotaRemainingPercent = try Int(reader.readVarint())
            case (15, .varint):
                weeklyQuotaRemainingPercent = try Int(reader.readVarint())
            case (17, .varint):
                dailyQuotaResetAtUnix = try Int64(reader.readVarint())
            case (18, .varint):
                weeklyQuotaResetAtUnix = try Int64(reader.readVarint())
            default:
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }

        return WindsurfGetPlanStatusResponse.PlanStatus(
            planInfo: planInfo,
            planStart: planStart,
            planEnd: planEnd,
            dailyQuotaRemainingPercent: dailyQuotaRemainingPercent,
            weeklyQuotaRemainingPercent: weeklyQuotaRemainingPercent,
            dailyQuotaResetAtUnix: dailyQuotaResetAtUnix,
            weeklyQuotaResetAtUnix: weeklyQuotaResetAtUnix,
            topUpStatus: topUpStatus,
            gracePeriodStatus: gracePeriodStatus)
    }

    private static func decodePlanInfo(
        from data: Data) throws -> WindsurfGetPlanStatusResponse.PlanStatus.PlanInfo
    {
        var reader = ProtoReader(data: data)
        var planName: String?
        var teamsTier: Int?

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                teamsTier = try Int(reader.readVarint())
            case (2, .lengthDelimited):
                planName = try reader.readString()
            default:
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }

        return WindsurfGetPlanStatusResponse.PlanStatus.PlanInfo(planName: planName, teamsTier: teamsTier)
    }

    private static func decodeTopUpStatus(
        from data: Data) throws -> WindsurfGetPlanStatusResponse.PlanStatus.TopUpStatus
    {
        var reader = ProtoReader(data: data)
        var topUpTransactionStatus: Int?

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                topUpTransactionStatus = try Int(reader.readVarint())
            default:
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }

        return WindsurfGetPlanStatusResponse.PlanStatus.TopUpStatus(
            topUpTransactionStatus: topUpTransactionStatus)
    }

    private static func decodeTimestamp(from data: Data) throws -> Date {
        var reader = ProtoReader(data: data)
        var seconds: Int64 = 0
        var nanos: Int32 = 0

        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                seconds = try Int64(reader.readVarint())
            case (2, .varint):
                nanos = try Int32(reader.readVarint())
            default:
                try reader.skipFieldBody(wireType: field.wireType)
            }
        }

        let timeInterval = TimeInterval(seconds) + (TimeInterval(nanos) / 1_000_000_000)
        return Date(timeIntervalSince1970: timeInterval)
    }

    private static func appendString(_ string: String, to data: inout Data) {
        let encoded = Data(string.utf8)
        self.appendVarint(UInt64(encoded.count), to: &data)
        data.append(encoded)
    }

    private static func appendFieldKey(_ fieldNumber: Int, wireType: ProtoWireType, to data: inout Data) {
        self.appendVarint(UInt64((fieldNumber << 3) | Int(wireType.rawValue)), to: &data)
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

enum WindsurfProtoError: LocalizedError {
    case truncated
    case invalidWireType(UInt64)
    case invalidUTF8
    case missingField(String)
    case unsupportedWireType(ProtoWireType)
    case malformedFieldKey

    var errorDescription: String? {
        switch self {
        case .truncated:
            "truncated protobuf payload"
        case let .invalidWireType(rawValue):
            "invalid wire type \(rawValue)"
        case .invalidUTF8:
            "invalid UTF-8 string"
        case let .missingField(name):
            "missing protobuf field \(name)"
        case let .unsupportedWireType(type):
            "unsupported protobuf wire type \(type.rawValue)"
        case .malformedFieldKey:
            "malformed protobuf field key"
        }
    }
}

enum ProtoWireType: UInt64 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

private struct ProtoField {
    let number: Int
    let wireType: ProtoWireType
}

private struct ProtoReader {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func nextField() throws -> ProtoField? {
        guard self.index < self.bytes.count else { return nil }
        let key = try self.readVarint()
        let number = Int(key >> 3)
        guard number > 0 else {
            throw WindsurfProtoError.malformedFieldKey
        }
        guard let wireType = ProtoWireType(rawValue: key & 0x07) else {
            throw WindsurfProtoError.invalidWireType(key & 0x07)
        }
        return ProtoField(number: number, wireType: wireType)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while self.index < self.bytes.count {
            let byte = self.bytes[self.index]
            self.index += 1

            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
            if shift >= 64 {
                throw WindsurfProtoError.truncated
            }
        }

        throw WindsurfProtoError.truncated
    }

    mutating func readLengthDelimitedData() throws -> Data {
        let length = try Int(self.readVarint())
        guard length >= 0, self.index + length <= self.bytes.count else {
            throw WindsurfProtoError.truncated
        }

        let chunk = Data(self.bytes[self.index..<(self.index + length)])
        self.index += length
        return chunk
    }

    mutating func readString() throws -> String {
        let data = try self.readLengthDelimitedData()
        guard let string = String(data: data, encoding: .utf8) else {
            throw WindsurfProtoError.invalidUTF8
        }
        return string
    }

    mutating func skipFieldBody(wireType: ProtoWireType) throws {
        switch wireType {
        case .varint:
            _ = try self.readVarint()
        case .fixed64:
            guard self.index + 8 <= self.bytes.count else { throw WindsurfProtoError.truncated }
            self.index += 8
        case .lengthDelimited:
            _ = try self.readLengthDelimitedData()
        case .fixed32:
            guard self.index + 4 <= self.bytes.count else { throw WindsurfProtoError.truncated }
            self.index += 4
        case .startGroup, .endGroup:
            throw WindsurfProtoError.unsupportedWireType(wireType)
        }
    }
}

#endif
