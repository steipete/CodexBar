import CodexBarCore
import Foundation

enum OpenAILiveUsageErrorText {
    static func message(_ error: any Error) -> String {
        if let error = error as? OpenAILiveUsageError { return self.message(usage: error) }
        if let error = error as? OpenAIOrgRateLimitsError {
            let usage: OpenAILiveUsageError = switch error {
            case .missingCredential: .missingCredential
            case .adminKeyRequired: .adminKeyRequired
            case .rateLimited: .rateLimited
            case let .apiFailure(code): .apiFailure(code)
            case .parseFailure: .parseFailure
            }
            return Self.message(usage: usage)
        }
        return error.localizedDescription
    }

    private static func message(usage: OpenAILiveUsageError) -> String {
        switch usage {
        case .missingCredential:
            L("Configure an OpenAI organization Admin API key in Settings → Providers → OpenAI.")
        case .adminKeyRequired:
            L("An OpenAI organization Admin API key with usage and project read permissions is required.")
        case .rateLimited:
            L("OpenAI API is rate limited.")
        case let .apiFailure(code):
            L("OpenAI API failed (HTTP %d).", code)
        case .parseFailure:
            L("Could not parse the OpenAI API response.")
        case .invalidWindow:
            L("Live usage supports 15-minute, 1-hour, and 6-hour windows.")
        }
    }
}
