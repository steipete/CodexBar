import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GrokWebBillingSnapshot: Sendable, Equatable {
    public let usedPercent: Double?
    public let resetsAt: Date?

    public init(usedPercent: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public enum GrokWebBillingError: LocalizedError, Sendable {
    case missingCredentials
    case emptyResponse
    case invalidResponse
    case requestFailed(Int, String)
    case rpcFailed(Int, String)
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
                "Grok web billing rejected credentials. Run `grok login` to refresh xAI auth."
            } else {
                "Grok web billing request failed with HTTP \(status): \(body)"
            }
        case let .rpcFailed(status, message):
            if status == 16 {
                "Grok web billing rejected credentials. Run `grok login` to refresh xAI auth."
            } else {
                "Grok web billing RPC failed with status \(status): \(message)"
            }
        case .parseFailed:
            "Could not parse Grok web billing usage."
        }
    }
}

public enum GrokWebBillingFetcher {
    public static let defaultEndpoint =
        URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!

    public static func fetch(
        credentials: GrokCredentials,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        try await self.fetch(
            authorizationHeader: "Bearer \(credentials.accessToken)",
            cookieHeader: nil,
            session: session,
            endpoint: endpoint)
    }

    public static func fetch(
        cookieHeader: String,
        session: URLSession = .shared,
        endpoint: URL = Self.defaultEndpoint) async throws -> GrokWebBillingSnapshot
    {
        try await self.fetch(
            authorizationHeader: nil,
            cookieHeader: cookieHeader,
            session: session,
            endpoint: endpoint)
    }

    private static func fetch(
        authorizationHeader: String?,
        cookieHeader: String?,
        session: URLSession,
        endpoint: URL) async throws -> GrokWebBillingSnapshot
    {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GrokWebBillingError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw GrokWebBillingError.requestFailed(http.statusCode, body)
        }
        try Self.validateGRPCStatusFields(Self.grpcHeaderFields(from: http.allHeaderFields))
        try Self.validateGRPCWebTrailers(data)

        return try Self.parseGRPCWebResponse(data)
    }

    static func parseGRPCWebResponse(_ data: Data, now: Date = Date()) throws -> GrokWebBillingSnapshot {
        let payloads = Self.grpcWebDataFrames(from: data)
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
        let reset = futureResetFields
            .filter { $0.path == [1, 5, 1] }
            .map(\.date)
            .min() ?? futureResetFields
            .map(\.date)
            .min()

        let noUsageYet = parsedPercent == nil &&
            scan.fixed32Fields.isEmpty &&
            reset != nil &&
            scan.varintFields.contains { $0.path.starts(with: [1, 6]) }
        guard let percent = parsedPercent ?? (noUsageYet ? 0 : nil) else {
            throw GrokWebBillingError.parseFailed
        }
        return GrokWebBillingSnapshot(usedPercent: percent, resetsAt: reset)
    }

    static func grpcWebDataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
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

    static func grpcHeaderFields(from headers: [AnyHashable: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in headers {
            let normalizedKey = String(describing: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedKey.hasPrefix("grpc-") else { continue }
            fields[normalizedKey] = String(describing: value)
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
            let length = (Int(bytes[index + 1]) << 24)
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
                    let value = line[line.index(after: separator)...]
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
                let bitPattern = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                scan.fixed32Fields.append(ProtobufScan.Fixed32Field(
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
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
