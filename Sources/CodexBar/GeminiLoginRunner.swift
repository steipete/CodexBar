import AppKit
import CodexBarCore
import Foundation

enum GeminiLoginRunner {
    private static let geminiConfigDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini")
    private static let credentialsFile = "oauth_creds.json"

    private static func clearCredentials() {
        let fm = FileManager.default
        let filesToDelete = [credentialsFile, "google_accounts.json"]
        for file in filesToDelete {
            let path = self.geminiConfigDir.appendingPathComponent(file)
            try? fm.removeItem(at: path)
        }
    }

    struct Result {
        enum Outcome {
            case success
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
    }

    static func run(onCredentialsCreated: (@Sendable () -> Void)? = nil) async -> Result {
        await Task(priority: .userInitiated) {
            let env = ProcessInfo.processInfo.environment
            guard let binary = BinaryLocator.resolveGeminiBinary(
                env: env,
                loginPATH: LoginShellPathCache.shared.current)
            else {
                return Result(outcome: .missingBinary)
            }

            // Clear existing credentials before auth (enables clean account switch)
            Self.clearCredentials()

            // Start watching for credentials file to be created
            if let callback = onCredentialsCreated {
                Self.watchForCredentials(callback: callback)
            }

            // Create a temporary shell script that runs gemini (auto-prompts for auth when no creds)
            let scriptContent = """
            #!/bin/bash
            cd ~
            "\(binary)"
            """

            let tempDir = FileManager.default.temporaryDirectory
            let scriptURL = tempDir.appendingPathComponent("gemini_login_\(UUID().uuidString).command")

            do {
                try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                try await NSWorkspace.shared.open(scriptURL, configuration: config)

                // Clean up script after Terminal has time to read it
                let scriptPath = scriptURL.path
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    try? FileManager.default.removeItem(atPath: scriptPath)
                }

                return Result(outcome: .success)
            } catch {
                return Result(outcome: .launchFailed(error.localizedDescription))
            }
        }.value
    }

    /// Watch for credentials file to be created, then call callback once
    private static func watchForCredentials(callback: @escaping @Sendable () -> Void, timeout: TimeInterval = 300) {
        let credsPath = self.geminiConfigDir.appendingPathComponent(self.credentialsFile).path

        DispatchQueue.global(qos: .utility).async {
            let startTime = Date()
            while Date().timeIntervalSince(startTime) < timeout {
                if FileManager.default.fileExists(atPath: credsPath) {
                    // Small delay to ensure file is fully written
                    Thread.sleep(forTimeInterval: 0.5)
                    callback()
                    return
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }
}
