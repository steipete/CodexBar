import CodexBarCore

/// Which Gemini migration sentinel the last refresh produced.
enum GeminiMigrationObservation {
    case none
    /// CodexBar could not read OAuth client credentials from the local Gemini CLI while Antigravity is
    /// installed. A local tooling problem: reinstalling or relaunching Gemini CLI is still the fix.
    case localAntigravityHandoff
    /// Google itself answered with the consumer-tier shutdown. Gemini CLI sign-in cannot succeed.
    case googleConsumerTierShutdown
}

extension UsageStore {
    /// Either sentinel: drives the "Enable Antigravity provider" settings action.
    var geminiObservedConsumerTierDeprecation: Bool {
        self.geminiMigrationObservation != .none
    }

    /// Only Google's own shutdown response. Narrower than `geminiObservedConsumerTierDeprecation` so the
    /// login guard cannot block a Workspace user whose local Gemini CLI install merely failed to yield
    /// OAuth client credentials.
    var geminiObservedGoogleConsumerTierShutdown: Bool {
        self.geminiMigrationObservation == .googleConsumerTierShutdown
    }

    static func isGeminiConsumerTierDeprecationError(_ error: Error?) -> Bool {
        switch error as? GeminiStatusProbeError {
        case .consumerTierDeprecated, .oauthCredentialsUnavailableWithAntigravity:
            true
        default:
            false
        }
    }

    func observeGeminiConsumerTierDeprecation(from error: Error) {
        switch error as? GeminiStatusProbeError {
        case .consumerTierDeprecated:
            self.geminiMigrationObservation = .googleConsumerTierShutdown
        case .oauthCredentialsUnavailableWithAntigravity:
            // Never downgrade a shutdown already seen this session: Google's response is the stronger
            // signal, and a later local-tooling failure must not re-arm the destructive login path.
            if self.geminiMigrationObservation != .googleConsumerTierShutdown {
                self.geminiMigrationObservation = .localAntigravityHandoff
            }
        default:
            return
        }
    }

    func clearGeminiConsumerTierDeprecationObservation() {
        self.geminiMigrationObservation = .none
    }
}
