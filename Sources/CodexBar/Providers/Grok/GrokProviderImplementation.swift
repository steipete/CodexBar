import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct GrokProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .grok
}
