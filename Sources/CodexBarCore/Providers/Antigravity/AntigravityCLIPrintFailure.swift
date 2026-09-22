import Foundation

/// Maps an ``agy`` print-usage subprocess failure to a sanitized diagnostic.
///
/// Raw stderr must never reach the user: it can embed account-identifying URLs
/// (Google profile pictures), proxy details, or local paths. Every branch below
/// produces a fixed message so the classification stays reviewable.
public enum AntigravityCLIPrintFailure: Sendable, Equatable {
    case executableNotFound
    case launchFailed
    case exited(code: Int32, reason: ExitReason)

    public enum ExitReason: Sendable, Equatable {
        case unspecified
        case network
        case eligibilityNetwork
        case ineligible
    }

    var message: String {
        switch self {
        case .executableNotFound:
            return "agy executable not found"
        case .launchFailed:
            return "agy failed to launch"
        case let .exited(code, reason):
            let prefix = "agy exited \(code)"
            switch reason {
            case .unspecified:
                return prefix
            case .network:
                return prefix + "; a network request failed (check network or proxy settings)"
            case .eligibilityNetwork:
                return prefix + "; the eligibility check failed on a network request (check network or proxy settings)"
            case .ineligible:
                return prefix + "; the account is not eligible for Antigravity"
            }
        }
    }

    static func error(for failure: SubprocessRunnerError) -> AntigravityStatusProbeError {
        switch failure {
        case .timedOut:
            .timedOut
        case let .nonZeroExit(code, stderr):
            Self.nonZeroExitError(code: code, stderr: stderr)
        case .binaryNotFound:
            .cliReportFailed(.executableNotFound)
        case .launchFailed:
            .cliReportFailed(.launchFailed)
        case .outputTooLarge:
            .parseFailed("CLI usage report failed")
        }
    }

    private static func nonZeroExitError(code: Int32, stderr: String) -> AntigravityStatusProbeError {
        let text = stderr.lowercased()
        if AntigravityCLIAuthenticationPrompt.contains(Data(stderr.utf8))
            || Self.signInMarkers.contains(where: { text.contains($0) })
        {
            return .authenticationRequired
        }
        let eligibilityFailed = Self.eligibilityMarkers.contains { text.contains($0) }
        let networkFailed = Self.networkMarkers.contains {
            text.range(of: $0, options: .regularExpression) != nil
        }
        if eligibilityFailed {
            return .cliReportFailed(.exited(code: code, reason: networkFailed ? .eligibilityNetwork : .ineligible))
        }
        if networkFailed {
            return .cliReportFailed(.exited(code: code, reason: .network))
        }
        return .cliReportFailed(.exited(code: code, reason: .unspecified))
    }

    private static let signInMarkers = [
        "not logged in",
        "not signed in",
        "unauthenticated",
        "authentication required",
        "login required",
        "please log in",
        "please sign in",
    ]

    private static let eligibilityMarkers = [
        "eligibility check failed",
        "not eligible",
        "does not support google tos",
        "unsupported country",
        "unsupported region",
    ]

    /// Transport-shaped fragments Go CLIs print when a request dies on the wire.
    /// Regexes keep ``eof`` and friends from matching inside unrelated words.
    private static let networkMarkers = [
        #"\beof\b"#,
        #"\btimed out\b"#,
        #"\btimeout\b"#,
        #"\bdeadline exceeded\b"#,
        #"\bi/o timeout\b"#,
        #"\bno such host\b"#,
        #"\bdns\b"#,
        #"\bconnection refused\b"#,
        #"\bconnection reset\b"#,
        #"\bnetwork is unreachable\b"#,
        #"\bunreachable\b"#,
        #"\bproxy\b"#,
        #"\bcertificate\b"#,
        #"\btls\b"#,
        #"\bssl\b"#,
        #"get "http"#,
        #"post "http"#,
    ]
}
