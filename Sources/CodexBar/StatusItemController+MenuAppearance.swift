import AppKit

extension StatusItemController {
    static func systemMenuAppearanceName(
        interfaceStyle: String?,
        increaseContrast: Bool) -> NSAppearance.Name
    {
        let isDark = interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
        if increaseContrast {
            return isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
        }
        return isDark ? .darkAqua : .aqua
    }
}
