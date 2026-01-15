import CodexBarCore
import Foundation

@MainActor
struct AntigravityLoginRunner {
    enum Result {
        case success(email: String, refreshToken: String, projectId: String?)
        case cancelled
        case failed(String)
    }

    static func run() async -> Result {
        await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let result = await self.performLogin()
                continuation.resume(returning: result)
            }
        }
    }

    private static func performLogin() async -> Result {
        guard let antigravityPath = BinaryLocator.resolveAntigravityBinary() else {
            return .failed("Antigravity app not found. Please install Antigravity first.")
        }

        let env = ProcessInfo.processInfo.environment

        do {
            let processInfo = try await SubprocessRunner.run(
                binary: "/bin/ps",
                arguments: ["-ax", "-o", "pid=,command="],
                environment: env,
                timeout: 5.0,
                label: "antigravity-ps")

            let lines = processInfo.stdout.split(separator: "\n")
            for line in lines {
                let text = String(line)
                guard let match = matchProcessLine(text) else { continue }
                let lower = match.command.lowercased()
                guard lower.contains("language_server_macos") else { continue }
                guard isAntigravityCommandLine(lower) else { continue }
                guard let token = extractFlag("--csrf_token", from: match.command) else { continue }
                let port = extractPort("--extension_server_port", from: match.command)

                let pid = match.pid

                let csrfToken = token

                let result = await fetchAndStoreCredentials(
                    pid: pid,
                    csrfToken: csrfToken,
                    port: port,
                    timeout: 10.0)

                return result
            }

            return .failed("Antigravity is not running. Please start Antigravity and try again.")
        } catch {
            return .failed("Failed to detect Antigravity process: \(error.localizedDescription)")
        }
    }

    private static func fetchAndStoreCredentials(
        pid: Int,
        csrfToken: String,
        port: Int?,
        timeout: TimeInterval) async -> Result
    {
        guard let workingPort = port else {
            return .failed("Antigravity port not found. Please restart Antigravity.")
        }

        do {
            let email = try await fetchAccountEmail(
                port: workingPort,
                csrfToken: csrfToken,
                timeout: timeout)

            let refreshToken = try await fetchRefreshToken(
                pid: pid,
                port: workingPort,
                csrfToken: csrfToken,
                timeout: timeout)

            let projectId = try await fetchProjectId(
                port: workingPort,
                csrfToken: csrfToken,
                timeout: timeout)

            return .success(email: email, refreshToken: refreshToken, projectId: projectId)
        } catch {
            return .failed("Failed to fetch credentials: \(error.localizedDescription)")
        }
    }

    private static func fetchAccountEmail(port: Int, csrfToken: String, timeout: TimeInterval) async throws -> String {
        let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")

        let body: [String: Any] = [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "ideVersion": "unknown",
                "locale": "en",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(for: request)
        let decoder = JSONDecoder()
        let response = try decoder.decode(GetUserStatusResponse.self, from: data)

        guard let email = response.userStatus?.email else {
            throw NSError(domain: "AntigravityLogin", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Email not found in response"
            ])
        }

        return email
    }

    private static func fetchRefreshToken(pid: Int, port: Int, csrfToken: String, timeout: TimeInterval) async throws -> String {
        let env = ProcessInfo.processInfo.environment
        let result = try await SubprocessRunner.run(
            binary: "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="],
            environment: env,
            timeout: timeout,
            label: "antigravity-ps-pid")

        let commandLine = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let token = extractFlag("--refresh_token", from: commandLine) else {
            throw NSError(domain: "AntigravityLogin", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Refresh token not found in command line"
            ])
        }

        return token
    }

    private static func fetchProjectId(port: Int, csrfToken: String, timeout: TimeInterval) async throws -> String? {
        let url = URL(string: "https://127.0.0.1:\(port)/v1internal:loadCodeAssist")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("antigravity/1.0", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config, delegate: InsecureSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            return nil
        }

        guard http.statusCode == 200 else {
            return nil
        }

        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        return json?["project_id"] as? String
    }

    private struct ProcessLineMatch {
        let pid: Int
        let command: String
    }

    private static func matchProcessLine(_ line: String) -> ProcessLineMatch? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
        return ProcessLineMatch(pid: pid, command: String(parts[1]))
    }

    private static func isAntigravityCommandLine(_ command: String) -> Bool {
        if command.contains("--app_data_dir") && command.contains("antigravity") { return true }
        if command.contains("/antigravity/") || command.contains("\\antigravity\\") { return true }
        return false
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: flag))[=\\s]+([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[tokenRange])
    }

    private static func extractPort(_ flag: String, from command: String) -> Int? {
        guard let raw = extractFlag(flag, from: command) else { return nil }
        return Int(raw)
    }
}

private final class InsecureSessionDelegate: NSObject {}

extension InsecureSessionDelegate: URLSessionTaskDelegate {}

extension InsecureSessionDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let result = self.challengeResult(challenge)
        Task { @MainActor in
            completionHandler(result.disposition, result.credential)
        }
    }

    private func challengeResult(_ challenge: URLAuthenticationChallenge) -> (
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?)
    {
        #if canImport(FoundationNetworking)
        return (.performDefaultHandling, nil)
        #else
        if let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
        #endif
    }
}

private struct GetUserStatusResponse: Decodable {
    let userStatus: UserStatus?
}

private struct UserStatus: Decodable {
    let email: String?
}