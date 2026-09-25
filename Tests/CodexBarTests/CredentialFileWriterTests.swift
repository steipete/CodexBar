import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct CredentialFileWriterTests {
    @Test(arguments: [false, true])
    func `staging is private before writing and replacement preserves open readers`(existing: Bool) throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let url = root.appendingPathComponent("auth.json")
        let original = Data("original-synthetic".utf8)
        let replacement = Data("replacement-synthetic".utf8)
        if existing { try original.write(to: url) }
        let reader = existing ? try FileHandle(forReadingFrom: url) : nil
        defer { try? reader?.close() }
        let inspectEmpty: @Sendable (URL) throws -> Void = { (staged: URL) throws in
            let directory = staged.deletingLastPathComponent()
            #expect(directory.path != root.path)
            #expect(directory.deletingLastPathComponent().path == root.path)
            #expect(try Self.mode(directory) == 0o700)
            #expect(try Self.mode(staged) == 0o600)
            #expect(try Data(contentsOf: staged).isEmpty)
        }
        try CredentialFileWriter.$beforeWriteForTesting.withValue(inspectEmpty) {
            try CredentialFileWriter.writePrivate(replacement, to: url) { (staged: URL) throws in
                #expect(try Data(contentsOf: staged) == replacement)
                if existing {
                    #expect(try Data(contentsOf: url) == original)
                } else {
                    #expect(!FileManager.default.fileExists(atPath: url.path))
                }
            }
        }
        #expect(try Data(contentsOf: url) == replacement)
        #expect(try Self.mode(url) == 0o600)
        #expect(try Self.mode(root) == 0o755)
        if let reader { #expect(try reader.readToEnd() == original) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["auth.json"])
    }

    @Test(arguments: [false, true])
    func `failed write or publication preserves destination and cleans staging`(beforeWrite: Bool) throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("auth.json")
        let original = Data("original-synthetic".utf8)
        try original.write(to: url)
        let fail: @Sendable (URL) throws -> Void = { _ in throw CancellationError() }
        CredentialFileWriter.$beforeWriteForTesting.withValue(beforeWrite ? fail : nil) {
            CredentialFileWriter.$beforePublishForTesting.withValue(beforeWrite ? nil : fail) {
                #expect(throws: CancellationError.self) {
                    try CredentialFileWriter.writePrivate(Data("replacement".utf8), to: url)
                }
            }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["auth.json"])
    }

    @Test(arguments: ["config", "accounts", "antigravity", "live-auth", "cookie-cache"])
    func `credential stores use private staging before publication`(kind: String) throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("auth.json")
        let original = Data("original-synthetic".utf8)
        try original.write(to: url)
        #expect(throws: CancellationError.self) {
            let inspectStaged: @Sendable (URL) throws -> Void = { staged in
                #expect(try Self.mode(staged.deletingLastPathComponent()) == 0o700)
                #expect(try Self.mode(staged) == 0o600)
                #expect(try Data(contentsOf: url) == original)
                throw CancellationError()
            }
            try CredentialFileWriter.$beforePublishForTesting.withValue(inspectStaged) {
                switch kind {
                case "config":
                    try CodexBarConfigStore(fileURL: url).save(CodexBarConfig(providers: []))
                case "accounts":
                    try FileTokenAccountStore(fileURL: url).storeAccounts([:])
                case "antigravity":
                    try AntigravityOAuthCredentialsStore(fileURL: url).save(AntigravityOAuthCredentials(
                        accessToken: "synthetic", refreshToken: "synthetic", expiryDate: nil))
                case "live-auth":
                    try DefaultCodexLiveAuthSwapper().swapLiveAuthData(Data("synthetic".utf8), liveHomeURL: root)
                default:
                    CookieHeaderCache.store(
                        .init(cookieHeader: "session=synthetic", storedAt: Date(), sourceLabel: "fixture"),
                        to: url)
                    // The legacy cache deliberately swallows persistence failures.
                    #expect(try Data(contentsOf: url) == original)
                    throw CancellationError()
                }
            }
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["auth.json"])
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
