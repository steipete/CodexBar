#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore
@testable import SweetCookieKit

struct DevinSessionImporterTests {
    @Test
    func `repeated imports avoid whole store decoding and observe session replacement`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeLog([
            StorageEntry(key: "auth1_session", value: #"{"token":"auth1_synthetic-first"}"#),
        ], to: directory)
        let work = StorageWork()
        let cache = LevelDBReadCache(
            readData: { url in
                work.recordRead()
                return try Data(contentsOf: url)
            })

        try ChromiumLocalStorageReader.$levelDBCache.withValue(cache) {
            let first = try DevinSessionImporter.readLocalStorage(from: directory)
            #expect(DevinSessionImporter.accessToken(from: first) == "auth1_synthetic-first")
            #expect(work.fullStoreReads == 0)
            #expect(try DevinSessionImporter.readLocalStorage(from: directory) == first)
            #expect(work.fullStoreReads == 0)

            try Self.writeLog([
                StorageEntry(key: "auth1_session", value: #"{"token":"auth1_synthetic-replacement"}"#),
            ], to: directory)
            let replacement = try DevinSessionImporter.readLocalStorage(from: directory)
            #expect(DevinSessionImporter.accessToken(from: replacement) == "auth1_synthetic-replacement")
            #expect(work.fullStoreReads == 0)
            #expect(try DevinSessionImporter.readLocalStorage(from: directory) == replacement)
            #expect(work.fullStoreReads == 0)

            ChromiumLocalStorageReader.invalidateCache()
            #expect(try DevinSessionImporter.readLocalStorage(from: directory) == replacement)
            #expect(work.fullStoreReads == 0)
        }
    }

    private final class StorageWork: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0

        var fullStoreReads: Int {
            self.lock.withLock { self.reads }
        }

        func recordRead() {
            self.lock.withLock { self.reads += 1 }
        }
    }

    @Test(arguments: Browser.defaultImportOrder.filter(\.usesChromiumProfileStore))
    func `imports Devin from each supported Chromium browser without cookies`(_ browser: Browser) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("devin-browser-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try #require(ChromiumProfileLocator.roots(for: [browser], homeDirectories: [home]).first)
        let storage = root.url.appendingPathComponent("Profile 2/Local Storage/leveldb")
        try Self.writeLog([
            StorageEntry(key: "auth1_session", value: #"{"token":"auth1_synthetic-browser-fixture"}"#),
            StorageEntry(key: "last-internal-org-for-external-org-v1-example", value: #""org_example12345""#),
        ], to: storage)
        let detection = BrowserDetection(homeDirectory: home.path, cacheTTL: 0)
        let browsers = DevinSessionImporter.localStorageBrowsers(browserDetection: detection)
        #expect(browsers == [browser])
        let candidates = ChromiumProfileLocator.roots(for: browsers, homeDirectories: [home]).flatMap {
            ChromiumLocalStorageDiscovery.profileCandidates(root: $0.url, labelPrefix: $0.labelPrefix)
        }

        let sessions = try DevinSessionImporter.importSessions(browserDetection: detection, candidates: candidates)

        #expect(sessions.count == 1)
        #expect(sessions.first?.sourceLabel == "\(browser.displayName) Profile 2")
        #expect(sessions.first?.accessToken == "auth1_synthetic-browser-fixture")
        #expect(sessions.first?.internalOrganizationID == "org_example12345")
    }

    @Test(arguments: [false, true])
    func `an unreadable profile only fails import when no other session is available`(_ hasSession: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeLog(hasSession ? [
            StorageEntry(key: "auth1_session", value: #"{"token":"auth1_synthetic-session-fixture"}"#),
        ] : [], to: directory)
        let candidates = [
            ChromiumLocalStorageDiscovery.Candidate(
                label: "Missing profile",
                url: directory.appendingPathComponent("gone")),
            ChromiumLocalStorageDiscovery.Candidate(label: "Readable profile", url: directory),
        ]

        do {
            let sessions = try DevinSessionImporter.importSessions(
                browserDetection: BrowserDetection(homeDirectory: directory.path, cacheTTL: 0),
                candidates: candidates)
            #expect(hasSession)
            #expect(sessions.map(\.sourceLabel) == ["Readable profile"])
        } catch DevinUsageError.browserStorageUnreadable {
            #expect(!hasSession)
        }
    }

    @Test
    func `no discovered profiles is not a storage read failure`() throws {
        let sessions = try DevinSessionImporter.importSessions(
            browserDetection: BrowserDetection(cacheTTL: 0),
            candidates: [])

        #expect(sessions.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `token extraction preserves auth1 then auth0 then fallback priority`(_ auth1: Bool, _ auth0: Bool) {
        let storage = [
            "auth1_session": auth1 ? #"{"token":"auth1_synthetic-session-fixture"}"# : "{}",
            "@@auth0spajs@@::client": auth0 ? #"{"access_token":"eyJsynthetic.auth0-token.signature"}"# : "{}",
            "fallback": #"{"accessToken":"eyJsynthetic.fallback-token.signature"}"#,
        ]
        let expected = auth1 ? "auth1_synthetic-session-fixture" :
            (auth0 ? "eyJsynthetic.auth0-token.signature" : "eyJsynthetic.fallback-token.signature")

        #expect(DevinSessionImporter.accessToken(from: storage) == expected)
    }

    @Test(arguments: [false, true])
    func `readable empty storage is an empty session`(_ hasHiddenFile: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeLog([], to: directory)
        if hasHiddenFile {
            let hidden = directory.appendingPathComponent(".ignored.log")
            try Data().write(to: hidden)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        }

        #expect(try DevinSessionImporter.readLocalStorage(from: directory).isEmpty)
    }

    @Test(arguments: [false, true])
    func `unreadable storage is not reported as an empty session`(_ unreadableFile: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        try Self.writeLog([
            StorageEntry(key: "auth1_session", value: #"{"token":"auth1_synthetic-session-fixture"}"#),
        ], to: directory)
        let blocked = unreadableFile ? directory.appendingPathComponent("000003.log") : directory
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)

        #expect(throws: (any Error).self) {
            _ = try DevinSessionImporter.readLocalStorage(from: directory)
        }
    }

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

        let session = try DevinSessionImporter.session(
            from: DevinSessionImporter.readLocalStorage(from: directory),
            sourceLabel: "Synthetic Chrome")

        #expect(session?.accessToken == (hasDevinSession ? currentToken : nil))
        #expect(session?.organization == (hasDevinSession ? "org/example" : nil))
        #expect(session?.internalOrganizationID == (hasDevinSession ? "org_example12345" : nil))
    }

    @Test(arguments: ["https://app.devin.ai", "https://app.devin.ai/^0https://example.org", "app.devin.ai"])
    func `origin scoped import keeps the current session`(_ origin: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentToken = "auth1_current-synthetic-session"
        try Self.writeLog([
            StorageEntry(origin: origin, key: "auth1_session", value: #"{"token":"auth1_stale-synthetic-session"}"#),
            StorageEntry(origin: origin, key: "auth1_session", value: #"{"token":"\#(currentToken)"}"#),
        ], to: directory)

        let storage = try DevinSessionImporter.readLocalStorage(from: directory)
        let session = try #require(DevinSessionImporter.session(from: storage, sourceLabel: "Synthetic Chrome"))

        #expect(session.accessToken == currentToken)
        #expect(storage.count == 1)
    }

    @Test(arguments: [
        "https://unrelated.example",
        "https://app.devin.ai.unrelated.example",
        "https://app.devin.ai@evil",
    ])
    func `origin scoped import rejects other origins`(_ origin: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devin-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.writeLog([
            StorageEntry(
                origin: origin,
                key: "auth1_session",
                value: #"{"token":"auth1_unrelated-synthetic-session"}"#),
        ], to: directory)

        #expect(try DevinSessionImporter.readLocalStorage(from: directory).isEmpty)
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

        let session = try DevinSessionImporter.session(
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

    @Test(arguments: ["records", "siblings", "array", "key-and-child"], [false, true])
    func `organization fields from unrelated records never form a pair`(_ shape: String, _ explicit: Bool) {
        let storage: [String: String] = switch shape {
        case "records":
            [
                "post-auth-v3-org_name-selected": "{}",
                "feature-flags-cache:org_unrelated123": "{}",
            ]
        case "siblings":
            ["member-info-v1": #"{"first":{"org_name":"selected"},"second":{"org_id":"org_unrelated123"}}"#]
        case "array":
            ["member-info-v1": #"[{"org_name":"selected"},{"org_id":"org_unrelated123"}]"#]
        default:
            ["post-auth-v3-org_name-selected": #"{"value":{"internalOrgId":"org_unrelated123"}}"#]
        }

        let result = DevinSessionImporter.organizationInfo(
            from: storage,
            organizationOverride: explicit ? "selected" : nil)

        #expect(result.organization == "org/selected")
        #expect(result.internalOrganizationID == nil)
    }

    @Test(arguments: [false, true])
    func `complete matching metadata wins over an incomplete candidate`(_ explicit: Bool) {
        let result = DevinSessionImporter.organizationInfo(
            from: [
                "a-post-auth-v3-org_name-selected": "{}",
                "member-info-v1": #"{"value":{"org_name":"selected","org_id":"org_selected123"}}"#,
                "feature-flags-cache:org_unrelated123": "{}",
            ],
            organizationOverride: explicit ? "selected" : nil)

        #expect(result.organization == "org/selected")
        #expect(result.internalOrganizationID == "org_selected123")
    }

    @Test
    func `post auth key slug retains its direct organization ID`() {
        let result = DevinSessionImporter.organizationInfo(
            from: ["post-auth-v3-org_name-selected": #"{"internalOrgId":"org_selected123"}"#],
            organizationOverride: nil)

        #expect(result.organization == "org/selected")
        #expect(result.internalOrganizationID == "org_selected123")
    }

    @Test(arguments: [false, true])
    func `conflicting key and JSON organizations stay separate`(_ explicit: Bool) {
        let result = DevinSessionImporter.organizationInfo(
            from: [
                "post-auth-v3-org_name-selected": #"{"orgName":"other","internalOrgId":"org_other12345"}"#,
            ],
            organizationOverride: explicit ? "selected" : nil)

        #expect(result.organization == (explicit ? "org/selected" : "org/other"))
        #expect(result.internalOrganizationID == (explicit ? nil : "org_other12345"))
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
