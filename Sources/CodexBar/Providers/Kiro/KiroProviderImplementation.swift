import CodexBarCore
import CodexBarMacroSupport
import Foundation

@ProviderImplementationRegistration
struct KiroProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .kiro
}
