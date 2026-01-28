import Foundation

#if os(macOS)
import SQLite3

public enum AntigravityLocalImporter {
    public struct LocalCredentialInfo: Sendable {
        public let accessToken: String?
        public let refreshToken: String?
        public let email: String?
        public let name: String?

        public var hasAccessToken: Bool {
            guard let accessToken else { return false }
            return !accessToken.isEmpty
        }

        public var hasRefreshToken: Bool {
            guard let refreshToken else { return false }
            return !refreshToken.isEmpty
        }
    }

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
        let dbPath = self.stateDbPath()
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            throw AntigravityOAuthCredentialsError.notFound
        }

        var refreshToken: String?
        if let protoInfo = try? self.readProtoTokenInfo(dbPath: dbPath) {
            refreshToken = protoInfo.refreshToken
        }

        if let authStatus = try? self.readAuthStatus(dbPath: dbPath) {
            return LocalCredentialInfo(
                accessToken: authStatus.apiKey,
                refreshToken: refreshToken,
                email: authStatus.email,
                name: authStatus.name)
        }

        if let refreshToken, !refreshToken.isEmpty {
            return LocalCredentialInfo(
                accessToken: nil,
                refreshToken: refreshToken,
                email: nil,
                name: nil)
        }

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
        let base64 = try self.readStateValue(dbPath: dbPath, key: "jetskiStateSync.agentManagerInitState")
        guard let data = Data(base64Encoded: base64) else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Invalid base64 in agentManagerInitState")
        }
        return try self.parseProtoTokenInfo(data: data)
    }

    private static func readStateValue(dbPath: URL, key: String) throws -> String {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db else {
            throw AntigravityOAuthCredentialsError.decodeFailed("Failed to open state.vscdb: \(openStatus)")
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
        var accessToken: String?
        var refreshToken: String?
        var tokenType: String?
        var expirySeconds: Int?

        var offset = 0
        while offset < data.count {
            let (fieldTag, newOffset) = try self.readVarint(data: data, offset: offset)
            offset = newOffset

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch wireType {
            case 0:
                let (value, nextOffset) = try self.readVarint(data: data, offset: offset)
                offset = nextOffset
                if fieldNumber == 4 {
                    expirySeconds = value
                }
            case 2:
                let (length, lengthOffset) = try self.readVarint(data: data, offset: offset)
                offset = lengthOffset
                let endOffset = offset + length
                guard endOffset <= data.count else {
                    throw AntigravityOAuthCredentialsError.decodeFailed("Invalid protobuf length")
                }
                let stringData = data[offset..<endOffset]
                let stringValue = String(data: stringData, encoding: .utf8)
                offset = endOffset

                switch fieldNumber {
                case 1:
                    accessToken = stringValue
                case 5:
                    tokenType = stringValue
                case 6:
                    refreshToken = stringValue
                default:
                    break
                }
            default:
                throw AntigravityOAuthCredentialsError.decodeFailed("Unsupported wire type: \(wireType)")
            }
        }

        return ProtoTokenInfo(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expirySeconds: expirySeconds)
    }

    private static func readVarint(data: Data, offset: Int) throws -> (Int, Int) {
        var result = 0
        var shift = 0
        var pos = offset

        while pos < data.count {
            let byte = Int(data[pos])
            result |= (byte & 0x7F) << shift
            pos += 1
            if (byte & 0x80) == 0 {
                return (result, pos)
            }
            shift += 7
            if shift > 63 {
                throw AntigravityOAuthCredentialsError.decodeFailed("Varint too long")
            }
        }

        throw AntigravityOAuthCredentialsError.decodeFailed("Incomplete varint")
    }
}
#endif
