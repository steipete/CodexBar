import AppAuth
import AppKit
import CodexBarCore
import Foundation

struct CodexLoginRunner {
    enum Phase {
        case requesting
        case waitingBrowser
    }

    struct Result {
        enum Outcome {
            case success
            case timedOut
            case failed(status: Int32)
            case missingBinary
            case launchFailed(String)
        }

        let outcome: Outcome
        let output: String
    }

    private static let authorizationEndpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let redirectPort: UInt16 = 1455
    private static let redirectURL = URL(string: "http://localhost:1455/auth/callback")!
    private static let successURL = URL(string: "https://chatgpt.com/")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let scopes = ["openid", "profile", "email", "offline_access"]
    private static let additionalParameters = [
        "id_token_add_organizations": "true",
        "codex_cli_simplified_flow": "true",
        "originator": "codex_cli_rs",
    ]

    @MainActor
    static func run(
        timeout: TimeInterval = 120,
        onPhaseChange: (@Sendable (Phase) -> Void)? = nil,
        credentialSource: String? = nil) async -> Result
    {
        let coordinator = NativeOAuthCoordinator(
            onPhaseChange: onPhaseChange,
            credentialSource: credentialSource)
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                await coordinator.run()
            }
            group.addTask {
                let nanos = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return await coordinator.cancelForTimeout()
            }
            let result = await group.next() ?? Result(outcome: .timedOut, output: "Codex login timed out.")
            group.cancelAll()
            return result
        }
    }

    static func _authorizationRequestForTesting(listenerBaseURL: URL) -> OIDAuthorizationRequest {
        Self.makeAuthorizationRequest(listenerBaseURL: listenerBaseURL)
    }

    @MainActor
    private final class NativeOAuthCoordinator {
        private let onPhaseChange: (@Sendable (Phase) -> Void)?
        private let credentialSource: String?
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var hasCompleted = false
        private var redirectHandler: OIDRedirectHTTPHandler?

        init(onPhaseChange: (@Sendable (Phase) -> Void)?, credentialSource: String?) {
            self.onPhaseChange = onPhaseChange
            self.credentialSource = credentialSource
        }

        func run() async -> Result {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.start()
            }
        }

        func cancelForTimeout() -> Result {
            self.redirectHandler?.cancelHTTPListener()
            let result = Result(outcome: .timedOut, output: "Codex login timed out.")
            self.finish(result)
            return result
        }

        private func start() {
            self.onPhaseChange?(.requesting)

            let configuration = OIDServiceConfiguration(
                authorizationEndpoint: CodexLoginRunner.authorizationEndpoint,
                tokenEndpoint: CodexLoginRunner.tokenEndpoint)
            let redirectHandler = OIDRedirectHTTPHandler(successURL: CodexLoginRunner.successURL)
            self.redirectHandler = redirectHandler

            var listenerError: NSError?
            let listenerBaseURL = redirectHandler.startHTTPListener(
                &listenerError,
                withPort: CodexLoginRunner.redirectPort)
            if let listenerError {
                let message = listenerError.localizedDescription
                self.finish(Result(outcome: .launchFailed(message), output: message))
                return
            }

            let request = CodexLoginRunner.makeAuthorizationRequest(
                configuration: configuration,
                listenerBaseURL: listenerBaseURL)

            self.onPhaseChange?(.waitingBrowser)
            redirectHandler.currentAuthorizationFlow = OIDAuthState
                .authState(byPresenting: request) { authState, error in
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    redirectHandler.cancelHTTPListener()

                    if let authState {
                        do {
                            let credentials = try Self.credentials(from: authState)
                            if let credentialSource = self.credentialSource {
                                try CodexOAuthCredentialsStore.save(credentials, rawSource: credentialSource)
                            } else {
                                try CodexOAuthCredentialsStore.save(credentials)
                            }
                            self.finish(Result(outcome: .success, output: "Codex OAuth login complete."))
                        } catch {
                            self.finish(Result(
                                outcome: .launchFailed(error.localizedDescription),
                                output: error.localizedDescription))
                        }
                        return
                    }

                    let message = error?.localizedDescription ?? "Unknown OAuth login error."
                    self.finish(Result(outcome: .failed(status: 1), output: message))
                }
        }

        private func finish(_ result: Result) {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.hasCompleted, let continuation = self.continuation else { return }
            self.hasCompleted = true
            self.continuation = nil
            continuation.resume(returning: result)
        }

        private static func credentials(from authState: OIDAuthState) throws -> CodexOAuthCredentials {
            guard let tokenResponse = authState.lastTokenResponse,
                  let accessToken = tokenResponse.accessToken,
                  !accessToken.isEmpty
            else {
                throw CodexOAuthCredentialsError.missingTokens
            }

            let refreshToken = tokenResponse.refreshToken ?? authState.refreshToken ?? ""
            if refreshToken.isEmpty {
                throw CodexOAuthCredentialsError.missingTokens
            }

            let idToken = tokenResponse.idToken
            let accountId = CodexOAuthClaimResolver.accountID(accessToken: accessToken, idToken: idToken)

            return CodexOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: idToken,
                accountId: accountId,
                lastRefresh: Date())
        }
    }

    private static func makeAuthorizationRequest(listenerBaseURL: URL) -> OIDAuthorizationRequest {
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: Self.authorizationEndpoint,
            tokenEndpoint: Self.tokenEndpoint)
        return self.makeAuthorizationRequest(configuration: configuration, listenerBaseURL: listenerBaseURL)
    }

    private static func makeAuthorizationRequest(
        configuration: OIDServiceConfiguration,
        listenerBaseURL: URL) -> OIDAuthorizationRequest
    {
        _ = listenerBaseURL
        let state = OIDAuthorizationRequest.generateState()
        let codeVerifier = OIDAuthorizationRequest.generateCodeVerifier()
        let codeChallenge = OIDAuthorizationRequest.codeChallengeS256(forVerifier: codeVerifier)
        return OIDAuthorizationRequest(
            configuration: configuration,
            clientId: Self.clientID,
            clientSecret: nil,
            scope: Self.scopes.joined(separator: " "),
            redirectURL: Self.redirectURL,
            responseType: OIDResponseTypeCode,
            state: state,
            nonce: nil,
            codeVerifier: codeVerifier,
            codeChallenge: codeChallenge,
            codeChallengeMethod: OIDOAuthorizationRequestCodeChallengeMethodS256,
            additionalParameters: Self.additionalParameters)
    }
}
