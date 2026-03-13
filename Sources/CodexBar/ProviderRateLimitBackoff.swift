import CodexBarCore
import Foundation

struct ProviderRateLimitBackoff: Sendable {
    let retryAfter: TimeInterval?
}

extension Error {
    var rateLimitBackoff: ProviderRateLimitBackoff? {
        switch self {
        case let error as ClaudeUsageError:
            switch error {
            case let .oauthRateLimited(_, retryAfter):
                return ProviderRateLimitBackoff(retryAfter: retryAfter)
            case let .oauthFailed(message):
                return Self.fallbackRateLimitBackoff(from: message)
            default:
                return nil
            }
        case let error as ClaudeOAuthFetchError:
            if case let .serverError(statusCode, _, retryAfter) = error, statusCode == 429 {
                return ProviderRateLimitBackoff(retryAfter: retryAfter)
            }
            return nil
        case let error as PerplexityError:
            if case let .httpError(statusCode, retryAfter) = error, statusCode == 429 {
                return ProviderRateLimitBackoff(retryAfter: retryAfter)
            }
            return nil
        default:
            return Self.fallbackRateLimitBackoff(from: self.localizedDescription)
        }
    }

    private static func fallbackRateLimitBackoff(from description: String) -> ProviderRateLimitBackoff? {
        let lowered = description.lowercased()
        guard lowered.contains("429")
            || lowered.contains("rate limit")
            || lowered.contains("rate_limit")
            || lowered.contains("retry after")
        else {
            return nil
        }

        let retryAfter = Self.extractRetryAfter(from: description)
        return ProviderRateLimitBackoff(retryAfter: retryAfter)
    }

    private static func extractRetryAfter(from text: String) -> TimeInterval? {
        let pattern = #"retry after\s+(\d+(?:\.\d+)?)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let capture = Range(match.range(at: 1), in: text),
              let seconds = TimeInterval(text[capture])
        else {
            return nil
        }
        return seconds
    }
}
