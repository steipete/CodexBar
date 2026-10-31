import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

struct MiniMaxLocalStorageImporterTests {
    @Test(arguments: ChromiumLocalStorageDiscovery.defaultBrowsers)
    func `discovers each storage fallback across the Chromium catalog`(browser: Browser) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try #require(ChromiumProfileLocator.roots(for: [browser], homeDirectories: [home]).first)
        let profile = root.url.appendingPathComponent("Default")
        let databaseName = "https_platform.minimax.io_0.indexeddb.leveldb"
        for path in ["Local Storage/leveldb", "Session Storage", "IndexedDB/\(databaseName)"] {
            try FileManager.default.createDirectory(
                at: profile.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let detection = BrowserDetection(homeDirectory: home.path)
        let fixtures: [(ChromiumLocalStorageDiscovery.Storage, String, String)] = [
            (.localStorage, "Local Storage/leveldb", ""),
            (.sessionStorage, "Session Storage", " (Session Storage)"),
            (MiniMaxLocalStorageImporter.indexedDBStorage, "IndexedDB/\(databaseName)", " (IndexedDB)"),
        ]
        for (storage, path, suffix) in fixtures {
            let candidates = MiniMaxLocalStorageImporter.storageCandidates(
                browserDetection: detection, storage: storage, homeDirectories: [home])
            #expect(candidates.map { $0.url.resolvingSymlinksInPath().path } == [
                profile.appendingPathComponent(path).resolvingSymlinksInPath().path,
            ])
            #expect(candidates.map(\.label) == ["\(root.labelPrefix) Default\(suffix)"])
        }
    }

    @Test
    func `IndexedDB discovery keeps only MiniMax origins in supported profiles`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-indexeddb-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = [
            "https_platform.minimax.io_0", "https_www.minimax.io_0", "https_minimax.io_0",
            "https_platform.minimax.cn_0", "https_www.minimax.cn_0", "https_minimax.cn_0",
            "https_platform.minimaxi.com_0", "https_www.minimaxi.com_0", "https_minimaxi.com_0",
        ].map { "\($0).indexeddb.leveldb" }
        let excluded = [
            "https_other.example_0.indexeddb.leveldb",
            "https_minimax.io.evil_0.indexeddb.leveldb",
            "https_minimax.io_0.indexeddb.blob",
            ".https_minimax.io_0.indexeddb.leveldb",
        ]
        for profile in ["Default", "Profile 2", "user-work", "Guest Profile", ".hidden"] {
            for database in allowed + excluded {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("\(profile)/IndexedDB/\(database)"),
                    withIntermediateDirectories: true)
            }
        }
        let nonDirectory = root.appendingPathComponent("Default/IndexedDB/https_minimax.io_1.indexeddb.leveldb")
        try Data().write(to: nonDirectory)
        let candidates = ChromiumLocalStorageDiscovery.profileCandidates(
            root: root, labelPrefix: "Fixture", storage: MiniMaxLocalStorageImporter.indexedDBStorage)
        #expect(candidates.count == 27)
        #expect(Set(candidates.map(\.url.lastPathComponent)) == Set(allowed))
        #expect(candidates.map(\.label) == ["Default", "Profile 2", "user-work"].flatMap { profile in
            Array(repeating: "Fixture \(profile) (IndexedDB)", count: allowed.count)
        })
    }

    @Test
    func `extracts access tokens from JSON preferring long tokens`() {
        let shortToken = String(repeating: "b", count: 24)
        let longToken = String(repeating: "a", count: 72)
        let payload = """
        {"access_token":"\(shortToken)","nested":{"token":"\(longToken)"}}
        """

        let tokens = MiniMaxLocalStorageImporter._extractAccessTokensForTesting(payload)

        #expect(tokens.contains(longToken))
        #expect(tokens.contains(shortToken) == false)
    }

    @Test
    func `extracts group ID from JSON string`() {
        let payload = """
        {"user":{"groupId":"98765"}}
        """

        let groupID = MiniMaxLocalStorageImporter._extractGroupIDForTesting(payload)

        #expect(groupID == "98765")
    }

    @Test
    func `resolves group ID from JWT claims`() {
        let token = Self.makeJWT(payload: [
            "iss": "minimax",
            "group_id": "12345",
            "pad": String(repeating: "x", count: 80),
        ])

        #expect(MiniMaxLocalStorageImporter._isMiniMaxJWTForTesting(token))
        #expect(MiniMaxLocalStorageImporter._groupIDFromJWTForTesting(token) == "12345")
    }

    @Test
    func `rejects non mini max JW ts without signal`() {
        let token = Self.makeJWT(payload: [
            "iss": "other",
            "pad": String(repeating: "y", count: 80),
        ])

        #expect(MiniMaxLocalStorageImporter._isMiniMaxJWTForTesting(token) == false)
    }

    private static func makeJWT(payload: [String: Any]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let headerData = try? JSONSerialization.data(withJSONObject: header)
        let payloadData = try? JSONSerialization.data(withJSONObject: payload)
        let headerPart = self.base64URL(headerData ?? Data())
        let payloadPart = self.base64URL(payloadData ?? Data())
        let signature = String(repeating: "s", count: 32)
        return "\(headerPart).\(payloadPart).\(signature)"
    }

    private static func base64URL(_ data: Data) -> String {
        let raw = data.base64EncodedString()
        return raw
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
