import CodexBarCore
import Foundation

/// Result of asking a provider to make one of its accounts the System account.
enum SystemAccountSwitchOutcome: Equatable {
    case succeeded
    case failed(title: String, message: String)
    /// The provider's configuration changed while switching; the result no longer applies.
    case discarded
}
