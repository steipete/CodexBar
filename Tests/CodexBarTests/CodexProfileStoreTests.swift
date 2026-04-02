import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct CodexProfileStoreTests {
    @Test
    func `discovers codex profiles and skips malformed entries`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)

        try self.writeAuthFile(
            to: authURL,
            email: "current@example.com",
            plan: "plus",
            accountID: "acct-current")
        try self.writeAuthFile(
            to: profilesURL.appendingPathComponent("plus-b.json"),
            email: "plus-b@example.com",
            plan: "plus",
            accountID: "acct-b")
        try self.writeAuthFile(
            to: profilesURL.appendingPathComponent("plus-c.json"),
            email: "plus-c@example.com",
            plan: "plus",
            accountID: "acct-c")
        try Data("{\"broken\":true}".utf8).write(to: profilesURL.appendingPathComponent("broken.json"))
        try FileManager.default.createSymbolicLink(
            at: profilesURL.appendingPathComponent("linked.json"),
            withDestinationURL: profilesURL.appendingPathComponent("plus-b.json"))

        let profiles = CodexProfileStore.discover(authFileURL: authURL)

        #expect(profiles.map(\.alias) == ["Current", "plus-b", "plus-c"])
        #expect(profiles.contains(where: { $0.alias == "Current" && $0.isActiveInCodex }))
        #expect(!profiles.contains(where: { $0.alias == "broken" }))
        #expect(!profiles.contains(where: { $0.alias == "linked" }))
    }

    @Test
    func `selected profile falls back to current auth when saved selection is missing`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)

        try self.writeAuthFile(
            to: authURL,
            email: "current@example.com",
            plan: "plus",
            accountID: "acct-current")
        try self.writeAuthFile(
            to: profilesURL.appendingPathComponent("plus-a.json"),
            email: "plus-a@example.com",
            plan: "plus",
            accountID: "acct-a")

        let selected = CodexProfileStore.selectedDisplayProfile(
            selectedPath: profilesURL.appendingPathComponent("missing.json").path,
            authFileURL: authURL)

        #expect(selected?.alias == "Live")
        #expect(selected?.isActiveInCodex == true)
    }

    @Test
    func `selected profile stays unset when no active auth exists`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)

        try self.writeAuthFile(
            to: profilesURL.appendingPathComponent("plus-a.json"),
            email: "plus-a@example.com",
            plan: "plus",
            accountID: "acct-a")
        try self.writeAuthFile(
            to: profilesURL.appendingPathComponent("plus-b.json"),
            email: "plus-b@example.com",
            plan: "plus",
            accountID: "acct-b")

        let selected = CodexProfileStore.selectedDisplayProfile(
            selectedPath: nil,
            authFileURL: authURL)

        #expect(selected == nil)
    }

    @Test
    func `display profiles collapse live auth into matching saved profile`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)

        try self.writeAuthFile(
            to: authURL,
            email: "same@example.com",
            plan: "plus",
            accountID: "acct-same")
        try self.writeAuthFile(
            to: profilesURL.appendingPathComponent("plus-b.json"),
            email: "same@example.com",
            plan: "plus",
            accountID: "acct-same")

        let profiles = CodexProfileStore.displayProfiles(authFileURL: authURL)

        #expect(profiles.map(\.alias) == ["plus-b"])
        #expect(profiles.first?.isActiveInCodex == true)
    }

    @Test
    func `creates isolated codex execution environment for profile override`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profileURL = root.appendingPathComponent("plus-a.json")
        try self.writeAuthFile(
            to: profileURL,
            email: "plus-a@example.com",
            plan: "plus",
            accountID: "acct-a")

        let resolved = try CodexProfileExecutionEnvironment.resolvedEnvironment(from: [
            CodexProfileExecutionEnvironment.authFileOverrideKey: profileURL.path,
        ])
        defer { resolved.cleanup() }

        let codexHome = try #require(resolved.environment["CODEX_HOME"])
        let authURL = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        #expect(resolved.environment[CodexProfileExecutionEnvironment.authFileOverrideKey] == nil)
        #expect(FileManager.default.fileExists(atPath: authURL.path))
        #expect(try Data(contentsOf: authURL) == Data(contentsOf: profileURL))

        let dirPermissions = try FileManager.default.attributesOfItem(atPath: codexHome)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default
            .attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber
        #expect(dirPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)

        resolved.cleanup()
        #expect(FileManager.default.fileExists(atPath: codexHome) == false)
    }

    private func writeAuthFile(to url: URL, email: String, plan: String, accountID: String) throws {
        let token = Self.fakeJWT(email: email, plan: plan)
        let payload: [String: Any] = [
            "tokens": [
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "id_token": token,
                "account_id": accountID,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
            "https://api.openai.com/profile": ["email": email],
        ])) ?? Data()
        return "\(self.base64URL(header)).\(self.base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
