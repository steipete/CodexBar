import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct OpenCodeProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .opencode
}
