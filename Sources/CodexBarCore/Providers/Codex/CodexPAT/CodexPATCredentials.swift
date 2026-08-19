import Foundation

public struct CodexPATCredentials: Equatable, Sendable {
    public let token: String
    public let source: CodexOAuthCredentialSource

    public init(token: String, source: CodexOAuthCredentialSource = .codexHome) {
        self.token = token
        self.source = source
    }
}
