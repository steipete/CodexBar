import Foundation

struct GeminiTestEnvironment {
    enum GeminiCLILayout {
        case npmNested
        case nixShare
        case fnmBundle
        case homebrewBundle
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

        switch layout {
        case .npmNested:
            let oauthPath = base
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

        case .nixShare:
            let oauthPath = base
                .appendingPathComponent("share")
                .appendingPathComponent("gemini-cli")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli-core")
                .appendingPathComponent("dist")
                .appendingPathComponent("src")
                .appendingPathComponent("code_assist")
                .appendingPathComponent("oauth2.js")

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

        case .fnmBundle:
            // Mirror a real fnm multishell layout: bin/gemini is a single relative
            // symlink into the same multishell's lib/node_modules/@google/gemini-cli,
            // which is a plain directory with the real package.json + bundle/*.js.
            let multishellRoot = self.homeURL
                .appendingPathComponent("Library")
                .appendingPathComponent("Caches")
                .appendingPathComponent("fnm_multishells")
                .appendingPathComponent("12345_67890")
            let binDir = multishellRoot.appendingPathComponent("bin")
            let packageRoot = multishellRoot
                .appendingPathComponent("lib")
                .appendingPathComponent("node_modules")
                .appendingPathComponent("@google")
                .appendingPathComponent("gemini-cli")
            let bundleDir = packageRoot.appendingPathComponent("bundle")
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

            let packageJSON = """
            {
              "name": "@google/gemini-cli"
            }
            """
            try packageJSON.write(
                to: packageRoot.appendingPathComponent("package.json"),
                atomically: true,
                encoding: .utf8)

            let chunkName = "chunk-TEST123.js"
            let geminiEntry = bundleDir.appendingPathComponent("gemini.js")
            let geminiContent = """
            #!/usr/bin/env node
            import { start } from "./\(chunkName)";
            start();
            """
            try geminiContent.write(to: geminiEntry, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: geminiEntry.path)

            let chunkContent = if includeOAuth {
                """
                export const start = () => {};
                const OAUTH_CLIENT_ID = 'test-client-id';
                const OAUTH_CLIENT_SECRET = 'test-client-secret';
                """
            } else {
                "export const start = () => {};\n"
            }
            try chunkContent.write(
                to: bundleDir.appendingPathComponent(chunkName),
                atomically: true,
                encoding: .utf8)

            // Relative symlink matching what fnm actually creates:
            //   fnm_multishells/XXX/bin/gemini -> ../lib/node_modules/@google/gemini-cli/bundle/gemini.js
            // Use the path-based API so the target is stored as a literal relative
            // string; the URL-based API resolves URL(fileURLWithPath: "../...") against
            // the process CWD, which produces a bogus absolute target.
            let geminiBinary = binDir.appendingPathComponent("gemini")
            try FileManager.default.createSymbolicLink(
                atPath: geminiBinary.path,
                withDestinationPath: "../lib/node_modules/@google/gemini-cli/bundle/gemini.js")

            return geminiBinary

        case .homebrewBundle:
            return try self.writeFakeHomebrewGeminiCLI(base: base, includeOAuth: includeOAuth)
        }
    }

    private func writeFakeHomebrewGeminiCLI(base: URL, includeOAuth: Bool) throws -> URL {
        let cellarRoot = base
            .appendingPathComponent("Cellar")
            .appendingPathComponent("gemini-cli")
            .appendingPathComponent("0.41.2")
        let binDir = cellarRoot.appendingPathComponent("bin")
        let packageRoot = cellarRoot
            .appendingPathComponent("libexec")
            .appendingPathComponent("lib")
            .appendingPathComponent("node_modules")
            .appendingPathComponent("@google")
            .appendingPathComponent("gemini-cli")
        let bundleDir = packageRoot.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        let packageJSON = """
        {
          "name": "@google/gemini-cli"
        }
        """
        try packageJSON.write(
            to: packageRoot.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8)

        let entry = bundleDir.appendingPathComponent("gemini.js")
        try "#!/usr/bin/env node\nawait import('./gemini-HASH.js');\n".write(
            to: entry,
            atomically: true,
            encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: entry.path)
        try "export const run = () => {};\n".write(
            to: bundleDir.appendingPathComponent("gemini-HASH.js"),
            atomically: true,
            encoding: .utf8)

        let chunkContent = if includeOAuth {
            """
            var OAUTH_CLIENT_ID = "test-client-id";
            var OAUTH_CLIENT_SECRET = "test-client-secret";
            """
        } else {
            "export const unrelated = true;\n"
        }
        try chunkContent.write(
            to: bundleDir.appendingPathComponent("chunk-OAUTH.js"),
            atomically: true,
            encoding: .utf8)

        let geminiBinary = binDir.appendingPathComponent("gemini")
        try FileManager.default.createSymbolicLink(
            atPath: geminiBinary.path,
            withDestinationPath: "../libexec/lib/node_modules/@google/gemini-cli/bundle/gemini.js")
        return geminiBinary
    }

    func writeFakeFnm(
        currentVersion: String = "v24.6.0",
        npmRoot: String? = nil,
        geminiPackageJSONPath: String) throws -> URL
    {
        let binDir = self.homeURL.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let fnmPath = binDir.appendingPathComponent("fnm")
        let script = if let npmRoot {
            """
            #!/bin/bash
            if [ "$1" = "current" ]; then
              printf '%s\n' "\(currentVersion)"
              exit 0
            fi

            if [ "$1" = "exec" ] && [ "$4" = "npm" ] && [ "$5" = "root" ] && [ "$6" = "-g" ]; then
              printf '%s\n' "\(npmRoot)"
              exit 0
            fi

            if [ "$1" = "exec" ] && [ "$4" = "node" ]; then
              printf '%s\n' "\(geminiPackageJSONPath)"
              exit 0
            fi

            exit 1
            """
        } else {
            """
            #!/bin/bash
            if [ "$1" = "current" ]; then
              printf '%s\n' "\(currentVersion)"
              exit 0
            fi

            if [ "$1" = "exec" ]; then
              printf '%s\n' "\(geminiPackageJSONPath)"
              exit 0
            fi

            exit 1
            """
        }
        try script.write(to: fnmPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fnmPath.path)
        return fnmPath
    }
}
