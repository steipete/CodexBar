import CodexBarCore
import Foundation

struct ProviderPresentation {
    let detailLine: @MainActor (ProviderPresentationContext) -> String

    @MainActor
    static func standardDetailLine(context: ProviderPresentationContext) -> String {
        let rawVersion = context.store.version(for: context.provider) ?? L10n.tr("not detected")
        let versionText = L10n.localizedDynamicValue(rawVersion)
        if versionText == L10n.tr("not detected") {
            return L10n.format("Provider detail missing: %@ %@", context.metadata.displayName, versionText)
        }
        return L10n.format("Provider detail: %@ %@", context.metadata.displayName, versionText)
    }
}
