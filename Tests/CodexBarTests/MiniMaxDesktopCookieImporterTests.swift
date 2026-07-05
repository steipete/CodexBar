import CommonCrypto
import Foundation
import SQLite3
import Testing
@testable import CodexBarCore

#if os(macOS)
struct MiniMaxDesktopCookieImporterTests {
    @Test
    func `imports minimax agent cookies from desktop sqlite`() throws {
        let databaseURL = try self.makeCookiesDatabase(
            records: [
                (".www.minimaxi.com", "_token", "desktop-token-value", nil),
                ("agent.minimaxi.com", "_token", "agent-token-value", nil),
            ])
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let session = MiniMaxDesktopCookieImporter.importSession(databaseURL: databaseURL)
        #expect(session?.sourceLabel == "MiniMax Agent")
        #expect(session?.cookieHeader.contains("_token=desktop-token-value") == true)
        #expect(session?.cookieHeader.contains("agent-token-value") == false)
    }

    @Test
    func `imports platform console cookies from desktop sqlite`() throws {
        let databaseURL = try self.makeCookiesDatabase(
            records: [
                ("platform.minimaxi.com", "_token", "platform-token-value", nil),
            ])
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let session = MiniMaxDesktopCookieImporter.importSession(databaseURL: databaseURL)
        #expect(session?.cookieHeader.contains("_token=platform-token-value") == true)
    }

    @Test
    func `imports encrypted desktop cookies when plaintext value is empty`() throws {
        let password = "desktop-test-password"
        let encrypted = try self.makeEncryptedCookieValue(plaintext: "encrypted-token-value", password: password)
        let databaseURL = try self.makeCookiesDatabase(
            records: [
                (".www.minimaxi.com", "_token", "", encrypted),
            ])
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }

        let session = MiniMaxDesktopCookieImporter.importSession(
            databaseURL: databaseURL,
            decryptionKeys: [self.deriveKey(from: password)])
        #expect(session?.cookieHeader.contains("_token=encrypted-token-value") == true)
    }

    private func makeEncryptedCookieValue(plaintext: String, password: String) throws -> Data {
        let key = self.deriveKey(from: password)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let payload = plaintext.data(using: .utf8) ?? Data()
        var outLength = 0
        var out = Data(count: payload.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            payload.withUnsafeBytes { payloadBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            payloadBytes.baseAddress,
                            payload.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw MiniMaxDesktopCookieImportError.sqliteFailed("encrypt failed")
        }
        out.count = outLength
        var encrypted = Data("v10".utf8)
        encrypted.append(out)
        return encrypted
    }

    private func deriveKey(from password: String) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let keyLength = key.count
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.utf8CString.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passBytes.count - 1,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength)
                }
            }
        }
        return key
    }

    private func makeCookiesDatabase(
        records: [(String, String, String, Data?)]) throws -> URL
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-desktop-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("Cookies")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw MiniMaxDesktopCookieImportError.sqliteFailed("open failed")
        }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE cookies (
            host_key TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            encrypted_value BLOB
        );
        """
        guard sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK else {
            throw MiniMaxDesktopCookieImportError.sqliteFailed("create failed")
        }

        let insertSQL = "INSERT INTO cookies(host_key, name, value, encrypted_value) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MiniMaxDesktopCookieImportError.sqliteFailed("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }

        for (host, name, value, encrypted) in records {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 3, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let encrypted {
                _ = encrypted.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        stmt,
                        4,
                        bytes.baseAddress,
                        Int32(encrypted.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw MiniMaxDesktopCookieImportError.sqliteFailed("insert failed")
            }
        }

        return databaseURL
    }
}
#endif
