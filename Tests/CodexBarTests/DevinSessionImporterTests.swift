#if os(macOS)
import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct DevinSessionImporterTests {
    @Test(arguments: [false, true])
    func `browser import ignores authentication from other origins`(_ hasDevinSession: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentToken = "eyJsynthetic.current-devin-token.signature"
        var entries: [StorageEntry] = [
            StorageEntry(
                origin: "https://unrelated.example",
                key: "auth1_session",
                value: #"{"token":"auth1_unrelated-synthetic-session"}"#),
            StorageEntry(
                origin: "https://unrelated.example",
                key: "last-internal-org-for-external-org-v1-unrelated",
                value: #""org_unrelated123""#),
        ]
        if hasDevinSession {
            entries.append(StorageEntry(
                key: "@@auth0spajs@@::client::audience::scope",
                value: #"{"body":{"access_token":"\#(currentToken)"}}"#))
            entries.append(StorageEntry(
                key: "last-internal-org-for-external-org-v1-example",
                value: #""org_example12345""#))
        }
        try Self.writeLog(entries, to: directory)

        let session = DevinSessionImporter.session(
            from: DevinSessionImporter.readLocalStorage(from: directory),
            sourceLabel: "Synthetic Chrome")

        #expect(session?.accessToken == (hasDevinSession ? currentToken : nil))
        #expect(session?.organization == (hasDevinSession ? "org/example" : nil))
        #expect(session?.internalOrganizationID == (hasDevinSession ? "org_example12345" : nil))
    }

    @Test
    func `structured session takes precedence over stale raw entries`() throws {
        let currentToken = "auth1_current-synthetic-session"
        let current = #"{"token":"\#(currentToken)"}"#
        let storage = DevinSessionImporter.localStorageValues(from: [
            ChromiumLocalStorageEntry(
                origin: "https://app.devin.ai",
                key: "auth1_session",
                value: current,
                rawValueLength: current.utf8.count),
        ], textEntries: [
            ChromiumLevelDBTextEntry(
                key: "_https://app.devin.ai\u{0000}\u{0001}auth1_session",
                value: #"{"token":"auth1_stale-synthetic-session"}"#),
        ])

        let session = try #require(DevinSessionImporter.session(from: storage, sourceLabel: "Synthetic Chrome"))

        #expect(session.accessToken == currentToken)
        #expect(storage.count == 1)
    }

    @Test(arguments: ["https://app.devin.ai", "https://app.devin.ai/^0https://example.org", "app.devin.ai"])
    func `raw session fallback keeps the newest value for its Devin origin`(_ origin: String) throws {
        let currentToken = "auth1_current-synthetic-session"
        let key = "_\(origin)\u{0000}\u{0001}auth1_session"
        let storage = DevinSessionImporter.localStorageValues(from: [], textEntries: [
            ChromiumLevelDBTextEntry(key: key, value: #"{"token":"\#(currentToken)"}"#),
            ChromiumLevelDBTextEntry(key: key, value: #"{"token":"auth1_stale-synthetic-session"}"#),
        ])

        let session = try #require(DevinSessionImporter.session(from: storage, sourceLabel: "Synthetic Chrome"))

        #expect(session.accessToken == currentToken)
        #expect(storage.count == 1)
    }

    @Test(arguments: [
        "https://unrelated.example",
        "https://app.devin.ai.unrelated.example",
        "https://app.devin.ai@evil",
    ])
    func `raw session fallback rejects other origins`(_ origin: String) {
        let storage = DevinSessionImporter.localStorageValues(from: [], textEntries: [
            ChromiumLevelDBTextEntry(
                key: "_\(origin)\u{0000}\u{0001}auth1_session",
                value: #"{"token":"auth1_unrelated-synthetic-session"}"#),
        ])

        #expect(storage.isEmpty)
    }

    @Test
    func `browser import keeps a new session after signing in again`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentToken = "auth1_current-synthetic-session"
        try Self.writeLog([
            StorageEntry(key: "auth1_session", value: #"{"token":"auth1_deleted-synthetic-session"}"#),
            StorageEntry(key: "auth1_session", value: nil),
            StorageEntry(key: "auth1_session", value: #"{"token":"\#(currentToken)"}"#),
            StorageEntry(key: "last-internal-org-for-external-org-v1-example", value: #""org_example12345""#),
        ], to: directory)

        let session = DevinSessionImporter.session(
            from: DevinSessionImporter.readLocalStorage(from: directory),
            sourceLabel: "Synthetic Chrome")

        #expect(session?.accessToken == currentToken)
    }

    @Test(arguments: ["external", "post-auth", "feature-flags"], ["selected", "org_selected123"])
    func `explicit organization never inherits another cached organization`(
        _ metadata: String,
        _ organization: String)
    {
        let storage = switch metadata {
        case "external":
            ["last-internal-org-for-external-org-v1-unrelated": #""org_unrelated123""#]
        case "post-auth":
            ["post-auth-v3": #"{"orgName":"unrelated","internalOrgId":"org_unrelated123"}"#]
        default:
            ["feature-flags-cache:org_unrelated123": "{}"]
        }

        let result = DevinSessionImporter.organizationInfo(from: storage, organizationOverride: organization)

        #expect(result.organization == DevinUsageFetcher.normalizedOrganization(organization))
        #expect(result.internalOrganizationID == (organization == "org_selected123" ? organization : nil))
    }

    @Test(arguments: ["external", "post-auth"])
    func `explicit slug keeps its matching cached internal organization`(_ metadata: String) {
        let storage: [String: String] = if metadata == "external" {
            [
                "last-internal-org-for-external-org-v1-unrelated": #""org_unrelated123""#,
                "last-internal-org-for-external-org-v1-selected": #""org_selected123""#,
            ]
        } else {
            [
                "post-auth-v3-unrelated": #"{"orgName":"unrelated","internalOrgId":"org_unrelated123"}"#,
                "post-auth-v3-selected": #"{"orgName":"selected","internalOrgId":"org_selected123"}"#,
            ]
        }

        let result = DevinSessionImporter.organizationInfo(from: storage, organizationOverride: "selected")

        #expect(result.organization == "org/selected")
        #expect(result.internalOrganizationID == "org_selected123")
    }

    private struct StorageEntry {
        var origin = "https://app.devin.ai"
        let key: String
        let value: String?
    }

    private static func writeLog(_ entries: [StorageEntry], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var batch = Data(repeating: 0, count: 8)
        batch.append(contentsOf: self.littleEndianBytes(UInt32(entries.count)))
        for entry in entries {
            let key = Data("_\(entry.origin)\u{0000}\u{0001}\(entry.key)".utf8)
            batch.append(entry.value == nil ? 0 : 1)
            batch.append(self.varint32(key.count))
            batch.append(key)
            if let value = entry.value {
                let encoded = Data([1]) + Data(value.utf8)
                batch.append(self.varint32(encoded.count))
                batch.append(encoded)
            }
        }

        // A single synthetic LevelDB write batch; the reader does not require its checksum.
        var record = Data(repeating: 0, count: 4)
        record.append(contentsOf: self.littleEndianBytes(UInt16(batch.count)))
        record.append(1)
        record.append(batch)
        try record.write(to: directory.appendingPathComponent("000003.log"))
    }

    private static func varint32(_ value: Int) -> Data {
        var result = Data()
        var remaining = UInt32(value)
        while remaining >= 0x80 {
            result.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        result.append(UInt8(remaining))
        return result
    }

    private static func littleEndianBytes(_ value: some FixedWidthInteger) -> [UInt8] {
        let littleEndian = value.littleEndian
        return withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
#endif
