import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GrokWebBillingSnapshot: Sendable, Equatable {
    public let usedPercent: Double?
    public let resetsAt: Date?
    public let subscriptionTier: String?
    /// False when `usedPercent` was inferred rather than read off the wire. The credits frame can
    /// describe a billing period while carrying no percentage field at all, and that shape is
    /// reported as 0 for the surface's own no-usage-yet contract. A caller that merges two billing
    /// surfaces must not promote such a value to a published percent.
    public let usedPercentIsWirePublished: Bool

    public init(
        usedPercent: Double?,
        resetsAt: Date?,
        subscriptionTier: String? = nil,
        usedPercentIsWirePublished: Bool = true)
    {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.subscriptionTier = subscriptionTier
        self.usedPercentIsWirePublished = usedPercentIsWirePublished
    }

    /// Overlay the CLI settings plan name. Usage percent stays on the existing credits rules.
    func applying(subscriptionTier raw: String?) -> GrokWebBillingSnapshot {
        GrokWebBillingSnapshot(
            usedPercent: self.usedPercent,
            resetsAt: self.resetsAt,
            subscriptionTier: GrokPlan.displayName(from: raw) ?? self.subscriptionTier,
            usedPercentIsWirePublished: self.usedPercentIsWirePublished)
    }

    /// Keep period and plan metadata a second billing surface did not publish. Usage percent
    /// always stays with the surface that produced this snapshot, so an unknown percent is
    /// never backfilled from another response.
    func completing(with other: GrokWebBillingSnapshot) -> GrokWebBillingSnapshot {
        GrokWebBillingSnapshot(
            usedPercent: self.usedPercent,
            resetsAt: other.resetsAt ?? self.resetsAt,
            subscriptionTier: self.subscriptionTier ?? other.subscriptionTier,
            usedPercentIsWirePublished: self.usedPercentIsWirePublished)
    }
}

public enum GrokWebBillingError: LocalizedError, Sendable {
    case missingCredentials
    case emptyResponse
    case invalidResponse
    case requestFailed(Int, String)
    case rpcFailed(Int, String)
    case teamUsageUnsupported
    case parseFailed

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Grok web billing requires a signed-in grok.com browser session or `grok login`."
        case .emptyResponse:
            "Grok web billing returned no protobuf payload."
        case .invalidResponse:
            "Grok web billing returned an invalid response."
        case let .requestFailed(status, body):
            if status == 401 || status == 403 {
                Self.reauthMessage
            } else {
                "Grok web billing request failed with HTTP \(status): \(body)"
            }
        case let .rpcFailed(status, message):
            if Self.isWebKeyExchangeCredentialRejection(status: status, message: message) {
                Self.webKeyExchangeReauthMessage
            } else if Self.isAuthenticationFailure(status: status, message: message) {
                Self.reauthMessage
            } else {
                "Grok web billing RPC failed with status \(status): \(message)"
            }
        case .teamUsageUnsupported:
            "Grok team usage is unavailable from the current billing surface."
        case .parseFailed:
            "Could not parse Grok web billing usage."
        }
    }

    private static let reauthMessage =
        "Grok web billing rejected credentials. Sign in to grok.com in Chrome or run `grok login` to refresh xAI auth."
    private static let webKeyExchangeReauthMessage =
        "grok.com billing no longer accepts browser-cookie sign-in for this endpoint. Run `grok login` so CodexBar "
            + "can read usage via the Grok CLI token."

    static func isWebKeyExchangeCredentialRejection(status: Int, message: String) -> Bool {
        guard status == 16 else { return false }
        let lower = message.lowercased()
        return lower.contains("no-credentials") || lower.contains("no credentials presented")
    }

    static func isAuthenticationFailure(status: Int, message: String) -> Bool {
        if status == 16 {
            return true
        }
        guard status == 7 else { return false }
        let lower = message.lowercased()
        return lower.contains("bad-credentials") || lower.contains("unauthenticated")
            || (lower.contains("oauth2") && lower.contains("could not be validated"))
            || (lower.contains("access token")
                && (lower.contains("invalid") || lower.contains("expired")
                    || lower.contains("could not be validated")))
    }
}

public enum GrokWebBillingFetcher {
    public static let defaultEndpoint =
        URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// `GetGrokCreditsConfigRequest { usage_period_type: WEEKLY }` carried as a
    /// grpc-web frame (flags byte, big-endian payload length, payload `08 02`).
    ///
    /// grok.com's billing API rejects a zero-length request message with
    /// `grpc-status 13` ("Missing request message."), so the empty frame that
    /// this client previously sent is refused. The web client serializes the
    /// active usage period explicitly; proto3 omits zero-valued fields, so
    /// UNSPECIFIED would serialize to an empty message the API also rejects.
    /// SuperGrok plans are displayed as weekly limits.
    private static let weeklyCreditsConfigRequest = Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02])

    public static func fetch(
        credentials: GrokCredentials,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        try await self.fetch(
            authorizationHeader: "Bearer \(credentials.accessToken)",
            cookieHeader: nil,
            principalType: credentials.isExpired ? nil : credentials.principalType,
            transport: transport,
            endpoint: endpoint)
    }

    public static func fetch(
        cookieHeader: String,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        try await self.fetch(
            cookieHeader: cookieHeader,
            credentials: nil,
            session: transport,
            endpoint: endpoint)
    }

    public static func fetch(
        cookieHeader: String,
        credentials: GrokCredentials?,
        session transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        let authorizationHeader = credentials.flatMap { credential in
            credential.isExpired ? nil : "Bearer \(credential.accessToken)"
        }
        return try await self.fetch(
            authorizationHeader: authorizationHeader,
            cookieHeader: cookieHeader,
            principalType: credentials.flatMap { $0.isExpired ? nil : $0.principalType },
            transport: transport,
            endpoint: endpoint)
    }

    private static func fetch(
        authorizationHeader: String?,
        cookieHeader: String?,
        principalType: String?,
        transport: any ProviderHTTPTransport,
        endpoint: URL) async throws -> GrokWebBillingSnapshot
    {
        do {
            return try await self.fetchOnce(
                authorizationHeader: authorizationHeader,
                cookieHeader: cookieHeader,
                transport: transport,
                endpoint: endpoint)
        } catch {
            if self.shouldRetry(error) {
                do {
                    return try await self.fetchOnce(
                        authorizationHeader: authorizationHeader,
                        cookieHeader: cookieHeader,
                        transport: transport,
                        endpoint: endpoint)
                } catch {
                    throw self.classified(error, principalType: principalType)
                }
            }
            throw self.classified(error, principalType: principalType)
        }
    }

    private static func classified(_ error: Error, principalType: String?) -> Error {
        guard
            principalType?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("team") == .orderedSame,
                case let GrokWebBillingError.rpcFailed(status, message) = error,
                self.isTeamBillingUnavailable(status: status, message: message)
        else {
            return error
        }
        return GrokWebBillingError.teamUsageUnsupported
    }

    private static func fetchOnce(
        authorizationHeader: String?,
        cookieHeader: String?,
        transport: any ProviderHTTPTransport,
        endpoint: URL) async throws -> GrokWebBillingSnapshot
    {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Self.weeklyCreditsConfigRequest
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as URLError where error.code == .badServerResponse {
            throw GrokWebBillingError.invalidResponse
        } catch {
            throw error
        }
        guard response.statusCode == 200 else {
            let body = String(data: response.data.prefix(400), encoding: .utf8) ?? ""
            throw GrokWebBillingError.requestFailed(response.statusCode, body)
        }
        try Self.validateGRPCStatusFields(
            Self.grpcHeaderFields(from: response.response.allHeaderFields))
        try Self.validateGRPCWebTrailers(response.data)

        return try Self.parseGRPCWebResponse(response.data)
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut || urlError.code == .networkConnectionLost
        }
        if case let GrokWebBillingError.requestFailed(status, body) = error {
            if [408, 502, 503, 504].contains(status) {
                return true
            }
            return body.localizedCaseInsensitiveContains("timeout")
                || body.localizedCaseInsensitiveContains("deadline")
        }
        guard case let GrokWebBillingError.rpcFailed(status, message) = error else { return false }
        if status == 4 {
            return true
        }
        guard status == 1 else { return false }
        return message.localizedCaseInsensitiveContains("timeout")
            || message.localizedCaseInsensitiveContains("deadline")
            || message.localizedCaseInsensitiveContains("expired")
    }

    static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) throws
        -> GrokWebBillingSnapshot
    {
        var payloads = Self.grpcWebDataFrames(from: data)
        if payloads.isEmpty, Self.looksLikeProtobufPayload(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { throw GrokWebBillingError.emptyResponse }

        var scan = ProtobufScan()
        for payload in payloads {
            scan.merge(Self.scanProtobuf(payload, depth: 0))
        }

        let parsedPercent = scan.fixed32Fields
            .filter { field in
                field.path.last == 1 && field.value.isFinite && field.value >= 0 && field.value <= 100
            }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        let resetFields = scan.varintFields.compactMap { field -> (path: [UInt64], date: Date)? in
            let raw = field.value
            guard raw >= 1_700_000_000, raw <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(raw)))
        }
        let futureResetFields = resetFields.filter { $0.date > now }
        let reset =
            futureResetFields
                .filter { $0.path == [1, 5, 1] }
                .map(\.date)
                .min()
                ?? futureResetFields
                .map(\.date)
                .min()

        let hasUsagePeriod = scan.varintFields.contains { field in
            field.path.starts(with: [1, 6])
                || (field.path == [1, 8, 1] && (field.value == 1 || field.value == 2))
        }
        // A period that declares a per-period bound with an empty used amount is a fully
        // determined zero-usage response (Weekly SuperGrok Heavy limit frame): the wire
        // publishes the period limit at [1,4,2]/[1,5,2] and carries no used amount at all.
        // That zero is real, unlike a period-only frame with no limit, which stays unknown.
        let hasDefinedPeriodLimit = scan.varintFields.contains { field in
            (field.path == [1, 4, 2] || field.path == [1, 5, 2])
                && field.value > 0 && field.value < 1_000_000_000_000
        }
        let noUsageYet =
            parsedPercent == nil && scan.fixed32Fields.isEmpty && reset != nil && hasUsagePeriod
        let zeroUsageIsWirePublished =
            parsedPercent != nil || (noUsageYet && hasDefinedPeriodLimit)
        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            throw GrokWebBillingError.parseFailed
        }
        return GrokWebBillingSnapshot(
            usedPercent: percent,
            resetsAt: reset,
            usedPercentIsWirePublished: zeroUsageIsWirePublished)
    }

    static func looksLikeProtobufPayload(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    static func grpcWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index < bytes.count {
            guard index + 5 <= bytes.count else { return [] }
            let flags = bytes[index]
            let length =
                (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    static func validateGRPCWebTrailers(_ data: Data) throws {
        try self.validateGRPCStatusFields(self.grpcWebTrailerFields(from: data))
    }

    static func validateGRPCStatusFields(_ fields: [String: String]) throws {
        guard let rawStatus = fields["grpc-status"],
              let status = Int(rawStatus),
              status != 0
        else {
            return
        }
        throw GrokWebBillingError.rpcFailed(status, fields["grpc-message"] ?? "")
    }

    static func isTeamBillingUnavailable(status: Int, message: String) -> Bool {
        guard status == 9 else { return false }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "no personal team" || normalized == "no personal team."
    }

    static func grpcHeaderFields(from headers: [AnyHashable: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedKey.hasPrefix("grpc-") else { continue }
            fields[normalizedKey] =
                String(describing: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .removingPercentEncoding ?? ""
        }
        return fields
    }

    static func grpcWebTrailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length =
                (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0, let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = line[..<separator]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value =
                        line[line.index(after: separator)...]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    private struct ProtobufScan {
        struct Fixed32Field {
            var path: [UInt64]
            var value: Float
            var order: Int
        }

        struct VarintField {
            var path: [UInt64]
            var value: UInt64
        }

        var fixed32Fields: [Fixed32Field] = []
        var varintFields: [VarintField] = []

        mutating func merge(_ other: ProtobufScan) {
            self.fixed32Fields.append(contentsOf: other.fixed32Fields)
            self.varintFields.append(contentsOf: other.varintFields)
        }
    }

    private static func scanProtobuf(_ data: Data, depth: Int) -> ProtobufScan {
        self.scanProtobuf(data, depth: depth, path: [], order: 0).scan
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int) -> (scan: ProtobufScan, order: Int)
    {
        let bytes = [UInt8](data)
        var scan = ProtobufScan()
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            let fieldStart = index
            guard let key = Self.readVarint(bytes, index: &index), key != 0 else {
                index = fieldStart + 1
                continue
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = Self.readVarint(bytes, index: &index) {
                    scan.varintFields.append(ProtobufScan.VarintField(path: fieldPath, value: value))
                } else {
                    index = fieldStart + 1
                }
            case 1:
                guard index + 8 <= bytes.count else { return (scan, nextOrder) }
                index += 8
            case 2:
                guard let length = Self.readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    index = fieldStart + 1
                    continue
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = Self.scanProtobuf(
                        Data(bytes[start..<end]),
                        depth: depth + 1,
                        path: fieldPath,
                        order: nextOrder)
                    scan.merge(nested.scan)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (scan, nextOrder) }
                let bitPattern =
                    UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(
                    ProtobufScan.Fixed32Field(
                        path: fieldPath,
                        value: Float(bitPattern: bitPattern),
                        order: nextOrder))
                nextOrder += 1
                index += 4
            default:
                index = fieldStart + 1
            }
        }

        return (scan, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }
        return nil
    }
}
