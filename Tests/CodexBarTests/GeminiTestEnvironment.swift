import Foundation

struct GeminiTestEnvironment {
    enum GeminiCLILayout {
        case npmNested
        case nixShare
    }

    let homeURL: URL
    private let geminiDir: URL
    private let antigravityDir: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let geminiDir = root.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let antigravityDir = root
            .appendingPathComponent(".codexbar")
            .appendingPathComponent("antigravity")
        try FileManager.default.createDirectory(at: antigravityDir, withIntermediateDirectories: true)
        self.homeURL = root
        self.geminiDir = geminiDir
        self.antigravityDir = antigravityDir
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.homeURL)
    }

    func writeSettings(authType: String) throws {
        let payload: [String: Any] = [
            "security": [
                "auth": [
                    "selectedType": authType,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: self.geminiDir.appendingPathComponent("settings.json"), options: .atomic)
    }

    func writeCredentials(accessToken: String, refreshToken: String?, expiry: Date, idToken: String?) throws {
        var payload: [String: Any] = [
            "access_token": accessToken,
            "expiry_date": expiry.timeIntervalSince1970 * 1000,
        ]
        if let refreshToken { payload["refresh_token"] = refreshToken }
        if let idToken { payload["id_token"] = idToken }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: self.geminiDir.appendingPathComponent("oauth_creds.json"), options: .atomic)
    }

    func readCredentials() throws -> [String: Any] {
        let url = self.geminiDir.appendingPathComponent("oauth_creds.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    func writeAntigravityCredentials(
        accessToken: String,
        refreshToken: String?,
        expiry: Date,
        idToken: String? = nil,
        email: String? = nil,
        projectID: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil) throws
    {
        var payload: [String: Any] = [
            "access_token": accessToken,
            "expiry_date": expiry.timeIntervalSince1970 * 1000,
        ]
        if let refreshToken { payload["refresh_token"] = refreshToken }
        if let idToken { payload["id_token"] = idToken }
        if let email { payload["email"] = email }
        if let projectID { payload["project_id"] = projectID }
        if let clientID { payload["client_id"] = clientID }
        if let clientSecret { payload["client_secret"] = clientSecret }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: self.antigravityDir.appendingPathComponent("oauth_creds.json"), options: .atomic)
    }

    func readAntigravityCredentials() throws -> [String: Any] {
        let url = self.antigravityDir.appendingPathComponent("oauth_creds.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    func writeFakeGeminiCLI(includeOAuth: Bool = true, layout: GeminiCLILayout = .npmNested) throws -> URL {
        let base = self.homeURL.appendingPathComponent("gemini-cli")
        let binDir = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let oauthPath: URL = switch layout {
        case .npmNested:
            base
                .appendingPathComponent("lib")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli-core")
                .appendingPathComponent("dist")
                .appendingPathComponent("src")
                .appendingPathComponent("code_assist")
                .appendingPathComponent("oauth2.js")
        case .nixShare:
            base
                .appendingPathComponent("share")
                .appendingPathComponent("gemini-cli")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli-core")
                .appendingPathComponent("dist")
                .appendingPathComponent("src")
                .appendingPathComponent("code_assist")
                .appendingPathComponent("oauth2.js")
        }

        if includeOAuth {
            try FileManager.default.createDirectory(
                at: oauthPath.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            let oauthContent = """
            const OAUTH_CLIENT_ID = 'test-client-id';
            const OAUTH_CLIENT_SECRET = 'test-client-secret';
            """
            try oauthContent.write(to: oauthPath, atomically: true, encoding: .utf8)
        }

        let geminiBinary = binDir.appendingPathComponent("gemini")
        try "#!/bin/bash\nexit 0\n".write(to: geminiBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: geminiBinary.path)
        return geminiBinary
    }
}
