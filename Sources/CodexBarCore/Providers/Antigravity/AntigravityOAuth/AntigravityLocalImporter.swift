import Foundation
import SwiftProtobuf

#if os(macOS)
import SQLite3

public enum AntigravityLocalImporter {
    public struct LocalCredentialInfo: Sendable {
        public let accessToken: String?
        public let refreshToken: String?
        public let email: String?
        public let name: String?
        public let expiresAt: Date?

        public var hasAccessToken: Bool {
            guard let accessToken else { return false }
            return !accessToken.isEmpty
        }

        public var hasRefreshToken: Bool {
            guard let refreshToken else { return false }
            return !refreshToken.isEmpty
        }
    }

    private static let log = CodexBarLog.logger(LogCategories.antigravity)

    // Current Antigravity builds wrap OAuth state inside antigravityUnifiedStateSync.* keys.
    // Older builds used jetskiStateSync.agentManagerInitState / antigravityAuthStatus.
    private static let unifiedOAuthTokenKey = "antigravityUnifiedStateSync.oauthToken"
    private static let unifiedUserStatusKey = "antigravityUnifiedStateSync.userStatus"
    private static let legacyAgentManagerInitStateKey = "jetskiStateSync.agentManagerInitState"
    private static let legacyAuthStatusKey = "antigravityAuthStatus"
    private static let oauthTokenSentinel = "oauthTokenInfoSentinelKey"
    private static let userStatusSentinel = "userStatusSentinelKey"

    public static func stateDbPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Antigravity")
            .appendingPathComponent("User")
            .appendingPathComponent("globalStorage")
            .appendingPathComponent("state.vscdb")
    }

    public static func importCredentials() async throws -> LocalCredentialInfo {
        self.log.debug("Starting Antigravity DB import")

        let dbPath = self.stateDbPath()
        Self.log.debug("Database path: \(dbPath.path)")

        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            Self.log.debug("Database file not found at path")
            throw AntigravityOAuthCredentialsError.notFound
        }

        var refreshToken: String?
        var accessToken: String?
        var expiresAt: Date?

        let protoInfo: ProtoTokenInfo?
        do {
            protoInfo = try self.readProtoTokenInfo(dbPath: dbPath)
        } catch AntigravityOAuthCredentialsError.permissionDenied {
            throw AntigravityOAuthCredentialsError.permissionDenied
        } catch {
            protoInfo = nil
        }

        if let protoInfo {
            refreshToken = protoInfo.refreshToken
            accessToken = protoInfo.accessToken
            if let expiry = protoInfo.expirySeconds {
                expiresAt = Date(timeIntervalSince1970: TimeInterval(expiry))
            }
            Self.log.debug(
                """
                Extracted OAuth token info - access_token present: \(accessToken?.isEmpty == false), \
                refresh_token present: \(refreshToken?.isEmpty == false)
                """)
        }

        let authStatus: AuthStatus?
        do {
            authStatus = try self.readAuthStatus(dbPath: dbPath)
        } catch AntigravityOAuthCredentialsError.permissionDenied {
            throw AntigravityOAuthCredentialsError.permissionDenied
        } catch {
            authStatus = nil
        }

        if let authStatus {
            Self.log.debug(
                """
                Read auth status - email: \(authStatus.email ?? "none"), \
                apiKey present: \(authStatus.apiKey?.isEmpty == false)
                """)
            let finalAccessToken = accessToken ?? authStatus.apiKey
            Self.log.debug(
                """
                Import result - email: \(authStatus.email ?? "none"), \
                hasAccessToken: \(finalAccessToken?.isEmpty == false), hasRefreshToken: \(refreshToken?
                    .isEmpty == false)
                """)

            return LocalCredentialInfo(
                accessToken: finalAccessToken,
                refreshToken: refreshToken,
                email: authStatus.email,
                name: authStatus.name,
                expiresAt: expiresAt)
        }

        if let refreshToken, !refreshToken.isEmpty {
            Self.log.debug("Using refresh token only (no auth status found)")
            return LocalCredentialInfo(
                accessToken: accessToken,
                refreshToken: refreshToken,
                email: nil,
                name: nil,
                expiresAt: expiresAt)
        }

        Self.log.debug("No credentials found in database")
        throw AntigravityOAuthCredentialsError.notFound
    }

    public static func isAvailable() -> Bool {
        FileManager.default.fileExists(atPath: self.stateDbPath().path)
    }

    private struct AuthStatus {
        let apiKey: String?
        let email: String?
        let name: String?
    }

    private struct ProtoTokenInfo {
        let accessToken: String?
        let refreshToken: String?
        let tokenType: String?
        let expirySeconds: Int?
    }

    private static func readAuthStatus(dbPath: URL) throws -> AuthStatus {
        if let unified = try? self.readUnifiedUserStatus(dbPath: dbPath) {
            return unified
        }

        self.log.debug("Reading legacy antigravityAuthStatus JSON from DB")
        let json = try self.readStateValue(dbPath: dbPath, key: Self.legacyAuthStatusKey)
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid antigravityAuthStatus JSON")
        }

        let apiKey = (dict["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (dict["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return AuthStatus(apiKey: apiKey, email: email, name: name)
    }

    private static func readUnifiedUserStatus(dbPath: URL) throws -> AuthStatus {
        self.log.debug("Reading antigravityUnifiedStateSync.userStatus from DB")
        let base64 = try self.readStateValue(dbPath: dbPath, key: Self.unifiedUserStatusKey)
        let inner = try self.unwrapSentinelPayload(base64Text: base64, expectedSentinel: Self.userStatusSentinel)

        var name: String?
        var email: String?
        for field in ProtobufWireReader(data: inner) {
            guard case let .lengthDelimited(number, value) = field else { continue }
            switch number {
            case 3: name = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            case 7: email = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            default: continue
            }
        }

        if name == nil || name?.isEmpty == true, email == nil || email?.isEmpty == true {
            throw AntigravityOAuthCredentialsError.decodeFailed("userStatus contained no name or email")
        }

        return AuthStatus(apiKey: nil, email: email, name: name)
    }

    private static func readProtoTokenInfo(dbPath: URL) throws -> ProtoTokenInfo {
        if let unified = try? self.readUnifiedOAuthToken(dbPath: dbPath) {
            return unified
        }

        self.log.debug("Reading legacy jetskiStateSync.agentManagerInitState from DB")
        let base64 = try self.readStateValue(dbPath: dbPath, key: Self.legacyAgentManagerInitStateKey)
        Self.log.debug("Read base64 value, length: \(base64.count)")

        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid base64 in agentManagerInitState")
        }
        Self.log.debug("Decoded base64, data length: \(data.count)")

        let state = try AgentManagerInitState(serializedBytes: data)
        guard state.hasOauthToken else {
            throw AntigravityOAuthCredentialsError.decodeFailed("No oauth_token field found")
        }
        return self.makeProtoTokenInfo(from: state.oauthToken)
    }

    private static func readUnifiedOAuthToken(dbPath: URL) throws -> ProtoTokenInfo {
        self.log.debug("Reading antigravityUnifiedStateSync.oauthToken from DB")
        let base64 = try self.readStateValue(dbPath: dbPath, key: Self.unifiedOAuthTokenKey)
        let inner = try self.unwrapSentinelPayload(base64Text: base64, expectedSentinel: Self.oauthTokenSentinel)
        let oauth = try OAuthTokenInfo(serializedBytes: inner)
        return self.makeProtoTokenInfo(from: oauth)
    }

    private static func makeProtoTokenInfo(from oauth: OAuthTokenInfo) -> ProtoTokenInfo {
        var expirySeconds: Int?
        if oauth.hasExpiry {
            expirySeconds = Int(oauth.expiry.seconds)
        }
        return ProtoTokenInfo(
            accessToken: oauth.accessToken.isEmpty ? nil : oauth.accessToken,
            refreshToken: oauth.refreshToken.isEmpty ? nil : oauth.refreshToken,
            tokenType: oauth.tokenType.isEmpty ? nil : oauth.tokenType,
            expirySeconds: expirySeconds)
    }

    /// Antigravity's unified-state payload is double-wrapped: the DB value base64-decodes to a
    /// protobuf whose field 1 is a wrapper carrying a sentinel string (field 1) and a payload
    /// (field 2) whose field 1 is itself a base64-encoded protobuf of the real message.
    private static func unwrapSentinelPayload(base64Text: String, expectedSentinel: String) throws -> Data {
        let trimmed = base64Text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outer = Data(base64Encoded: trimmed) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid base64 in unified state value")
        }

        guard let wrapper = ProtobufWireReader.firstLengthDelimited(in: outer, fieldNumber: 1) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Missing wrapper field in unified state")
        }

        var sentinel: String?
        var payload: Data?
        for field in ProtobufWireReader(data: wrapper) {
            guard case let .lengthDelimited(number, value) = field else { continue }
            if number == 1, sentinel == nil {
                sentinel = String(data: value, encoding: .utf8)
            } else if number == 2, payload == nil {
                payload = value
            }
        }

        guard sentinel == expectedSentinel, let payload else {
            throw AntigravityOAuthCredentialsError.decodeFailed(
                "Unexpected sentinel \(sentinel ?? "nil") (expected \(expectedSentinel))")
        }

        guard let innerBase64Bytes = ProtobufWireReader.firstLengthDelimited(in: payload, fieldNumber: 1) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Missing inner payload for \(expectedSentinel)")
        }

        guard let innerText = String(data: innerBase64Bytes, encoding: .utf8),
              let decoded = Data(base64Encoded: innerText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw AntigravityOAuthCredentialsError
                .decodeFailed("Inner payload is not valid base64 for \(expectedSentinel)")
        }

        return decoded
    }

    private static func readStateValue(dbPath: URL, key: String) throws -> String {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db else {
            let sysErrno = db.map { sqlite3_system_errno($0) } ?? 0
            if let db { sqlite3_close(db) }
            if openStatus == SQLITE_CANTOPEN, sysErrno == EPERM || sysErrno == EACCES {
                throw AntigravityOAuthCredentialsError.permissionDenied
            }
            throw AntigravityOAuthCredentialsError
                .decodeFailed("Failed to open state.vscdb: \(openStatus), errno: \(sysErrno)")
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Failed to prepare query")
        }
        defer { sqlite3_finalize(stmt) }

        let keyCString = key.cString(using: .utf8)
        guard let keyCString else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Failed to convert key to UTF-8: \(key)")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, keyCString, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw AntigravityOAuthCredentialsError.notFound
        }

        guard let cValue = sqlite3_column_text(stmt, 0) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Empty value for key: \(key)")
        }

        let value = String(cString: cValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Empty value for key: \(key)")
        }

        return value
    }
}

/// Minimal protobuf wire-format reader for unwrapping Antigravity's sentinel envelopes without
/// introducing additional generated messages.
private struct ProtobufWireReader: Sequence, IteratorProtocol {
    enum Field {
        case varint(fieldNumber: Int, value: UInt64)
        case lengthDelimited(fieldNumber: Int, value: Data)
        case fixed64(fieldNumber: Int, value: UInt64)
        case fixed32(fieldNumber: Int, value: UInt32)
    }

    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    static func firstLengthDelimited(in data: Data, fieldNumber: Int) -> Data? {
        for field in ProtobufWireReader(data: data) {
            if case let .lengthDelimited(number, value) = field, number == fieldNumber {
                return value
            }
        }
        return nil
    }

    mutating func next() -> Field? {
        guard let tag = self.readVarint() else { return nil }
        let fieldNumber = Int(tag >> 3)
        let wireType = Int(tag & 0x7)
        switch wireType {
        case 0:
            guard let value = self.readVarint() else { return nil }
            return .varint(fieldNumber: fieldNumber, value: value)
        case 1:
            guard let value = self.readFixed64() else { return nil }
            return .fixed64(fieldNumber: fieldNumber, value: value)
        case 2:
            guard let length = self.readVarint() else { return nil }
            let end = self.offset + Int(length)
            guard end <= self.data.count else { return nil }
            let slice = self.data.subdata(in: self.data.startIndex + self.offset..<self.data.startIndex + end)
            self.offset = end
            return .lengthDelimited(fieldNumber: fieldNumber, value: slice)
        case 5:
            guard let value = self.readFixed32() else { return nil }
            return .fixed32(fieldNumber: fieldNumber, value: value)
        default:
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while self.offset < self.data.count {
            let byte = self.data[self.data.startIndex + self.offset]
            self.offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private mutating func readFixed64() -> UInt64? {
        guard self.offset + 8 <= self.data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self.data[self.data.startIndex + self.offset + i]) << (8 * i)
        }
        self.offset += 8
        return value
    }

    private mutating func readFixed32() -> UInt32? {
        guard self.offset + 4 <= self.data.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self.data[self.data.startIndex + self.offset + i]) << (8 * i)
        }
        self.offset += 4
        return value
    }
}
#endif
