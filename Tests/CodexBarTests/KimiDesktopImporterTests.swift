#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

struct KimiDesktopImporterTests {
    @Test
    func `imports current Desktop Local Storage without a legacy cookie`() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-import-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = home.appendingPathComponent("Library/Application Support/kimi-desktop/Local Storage/leveldb")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data("MANIFEST-000001\n".utf8).write(to: storage.appendingPathComponent("CURRENT"))
        // Synthetic checksummed manifest and WAL; the JWT has no valid service signature.
        let manifest = try #require(Data(base64Encoded: "KAYrrQYAAQIEAwUEAQ=="))
        try manifest.write(to: storage.appendingPathComponent("MANIFEST-000001"))
        let wal = try #require(Data(base64Encoded:
            "DA9ESZ0AAQEAAAAAAAAAAQAAAAEjX2h0dHBzOi8vd3d3LmtpbWkuY29tAAFhY2Nlc3NfdG9rZW5rAWV5SmhiR2NpT2" +
                "lKSVV6STFOaUo5LmV5SjBlWEFpT2lKaFkyTmxjM01pTENKaGRXUWlPaUpyYVcxcExtTnZiU0lzSW1WNGNDSTZOREV3" +
                "TWpRME5EZ3dNSDAuZml4dHVyZS1zaWduYXR1cmU="))
        try wal.write(to: storage.appendingPathComponent("000004.log"))
        let expected =
            "eyJhbGciOiJIUzI1NiJ9.eyJ0eXAiOiJhY2Nlc3MiLCJhdWQiOiJraW1pLmNvbSIsImV4cCI6NDEwMjQ" +
            "0NDgwMH0.fixture-signature"
        #expect(KimiCookieImporter.desktopAuthToken(region: .china, homeDirectory: home) == expected)
        #expect(KimiCookieImporter.desktopAuthToken(region: .international, homeDirectory: home) == nil)
    }
}
#endif
