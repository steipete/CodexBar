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
        self.log.debug("Reading antigravityAuthStatus from DB")
        let json = try self.readStateValue(dbPath: dbPath, key: "antigravityAuthStatus")
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

    private static func readProtoTokenInfo(dbPath: URL) throws -> ProtoTokenInfo {
        self.log.debug("Reading jetskiStateSync.agentManagerInitState from DB")
        let base64 = try self.readStateValue(dbPath: dbPath, key: "jetskiStateSync.agentManagerInitState")
        Self.log.debug("Read base64 value, length: \(base64.count)")

        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid base64 in agentManagerInitState")
        }
        Self.log.debug("Decoded base64, data length: \(data.count)")

        return try self.parseProtoTokenInfo(data: data)
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

    private static func parseProtoTokenInfo(data: Data) throws -> ProtoTokenInfo {
        self.log.debug("Parsing protobuf data using swift-protobuf")

        do {
            let state = try AgentManagerInitState(serializedBytes: data)
            Self.log.debug("Successfully parsed AgentManagerInitState")

            guard state.hasOauthToken else {
                Self.log.debug("No oauth_token field (field 6) found in protobuf")
                throw AntigravityOAuthCredentialsError.decodeFailed("No oauth_token field found")
            }

            let oauthToken = state.oauthToken
            Self.log.debug(
                """
                Found OAuthTokenInfo - access_token length: \(oauthToken.accessToken.count), \
                refresh_token length: \(oauthToken.refreshToken.count)
                """)

            var expirySeconds: Int?
            if oauthToken.hasExpiry {
                expirySeconds = Int(oauthToken.expiry.seconds)
                Self.log.debug("Token expiry: \(expirySeconds!) seconds since epoch")
            }

            return ProtoTokenInfo(
                accessToken: oauthToken.accessToken.isEmpty ? nil : oauthToken.accessToken,
                refreshToken: oauthToken.refreshToken.isEmpty ? nil : oauthToken.refreshToken,
                tokenType: oauthToken.tokenType.isEmpty ? nil : oauthToken.tokenType,
                expirySeconds: expirySeconds)
        } catch {
            self.log.debug("Protobuf parsing failed: \(error)")
            throw AntigravityOAuthCredentialsError.decodeFailed("Failed to parse protobuf: \(error)")
        }
    }
}
#endif
