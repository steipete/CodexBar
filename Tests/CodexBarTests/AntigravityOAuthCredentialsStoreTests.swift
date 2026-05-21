import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityOAuthCredentialsStoreTests {
    @Test
    func `oauth client discovery reads renamed legacy bundle`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyClient = AntigravityOAuthClient(
            clientID: self.googleClientID("legacy"),
            clientSecret: self.googleClientSecret(repeating: "a"))
        try self.writeAntigravityApp(
            named: "Antigravity 2.app",
            under: root,
            bundleIdentifier: "com.google.antigravity-ide",
            artifactRelativePath: "Contents/Resources/app/out/main.js",
            artifactData: Data("""
            out-build/vs/platform/cloudCode/common/oauthClient.js
            clientId="\(legacyClient.clientID)";
            clientSecret="\(legacyClient.clientSecret)";
            """.utf8))

        #expect(
            AntigravityOAuthConfig.discoverClientFromInstalledApp(
                applicationRoots: [root]) == legacyClient)
    }

    @Test
    func `oauth client discovery reads standalone antigravity 2 bundle`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let standaloneClient = AntigravityOAuthClient(
            clientID: self.googleClientID("standalone"),
            clientSecret: self.googleClientSecret(repeating: "b"))
        let alternateClient = AntigravityOAuthClient(
            clientID: self.googleClientID("alternate"),
            clientSecret: self.googleClientSecret(repeating: "c"))
        var artifactData = Data([0xFF])
        artifactData.append(Data(
            """
            \u{0}\(alternateClient.clientSecret)\u{0}\(standaloneClient.clientSecret)\
            \u{0}oauth_data\(standaloneClient.clientID)\u{0}\(alternateClient.clientID)\u{0}
            """.utf8))
        try self.writeAntigravityApp(
            named: "Antigravity.app",
            under: root,
            artifactRelativePath: "Contents/Resources/bin/language_server",
            artifactData: artifactData)

        #expect(
            AntigravityOAuthConfig.discoverClientFromInstalledApp(
                applicationRoots: [root]) == standaloneClient)
    }

    @Test
    func `oauth client discovery pairs lone binary secret with trailing client id`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let standaloneClient = AntigravityOAuthClient(
            clientID: self.googleClientID("standalone"),
            clientSecret: self.googleClientSecret(repeating: "b"))
        let alternateClientID = self.googleClientID("alternate")
        var artifactData = Data([0xFF])
        artifactData.append(Data(
            """
            \u{0}\(standaloneClient.clientSecret)\u{0}oauth_data\
            \u{0}\(alternateClientID)\u{0}\(standaloneClient.clientID)\u{0}
            """.utf8))
        try self.writeAntigravityApp(
            named: "Antigravity.app",
            under: root,
            artifactRelativePath: "Contents/Resources/bin/language_server",
            artifactData: artifactData)

        #expect(
            AntigravityOAuthConfig.discoverClientFromInstalledApp(
                applicationRoots: [root]) == standaloneClient)
    }

    @Test
    func `missing credentials message contains key diagnostic hints`() {
        let msg = AntigravityOAuthConfig.missingCredentialsMessage
        #expect(msg.contains("CodexBar could not discover Antigravity.app's OAuth client"))
        #expect(msg.contains("ANTIGRAVITY_OAUTH_CLIENT_ID"))
        #expect(msg.contains("ANTIGRAVITY_OAUTH_CLIENT_SECRET"))
        #expect(msg.contains("Antigravity CLI after migrating from Gemini CLI"))
    }

    private func writeAntigravityApp(
        named name: String,
        under root: URL,
        bundleIdentifier: String = "com.google.antigravity",
        artifactRelativePath: String,
        artifactData: Data) throws
    {
        let appURL = root.appendingPathComponent(name, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0)
        try infoData.write(to: infoURL)

        let artifactURL = appURL.appendingPathComponent(artifactRelativePath)
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try artifactData.write(to: artifactURL)
    }

    private func googleClientID(_ name: String) -> String {
        "123456789012-" + name + ".apps" + ".googleusercontent.com"
    }

    private func googleClientSecret(repeating character: Character) -> String {
        "GOC" + "SPX-" + String(repeating: character, count: 28)
    }
}
