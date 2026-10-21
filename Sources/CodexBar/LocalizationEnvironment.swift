import Foundation
import SwiftUI

func codexBarLocalizedLayoutDirection() -> LayoutDirection {
    Locale.Language(identifier: codexBarLocalizedResourceLocale().identifier).characterDirection == .rightToLeft
        ? .rightToLeft : .leftToRight
}

private struct CodexBarLocalizationEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(
                \.locale,
                codexBarLocalizationSignature().isEmpty
                    ? codexBarLocalizedLocale() : codexBarLocalizedResourceLocale())
            .environment(\.layoutDirection, codexBarLocalizedLayoutDirection())
    }
}

extension View {
    /// Keep native formatting and layout in the same language as the selected string resources.
    func codexBarLocalized() -> some View {
        self.modifier(CodexBarLocalizationEnvironment())
    }
}
