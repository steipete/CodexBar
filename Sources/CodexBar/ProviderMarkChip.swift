import CodexBarCore
import SwiftUI

/// The provider's real mark on a neutral plate washed with its own brand tint.
///
/// The tint only identifies; the glyph is the curated full-colour mark or the template mark in `ink`, so a
/// pale or mid-tone tint never decides the logo's contrast. Callers that render for export pass fixed plate,
/// keyline and ink tokens; in-app callers keep the adaptive defaults.
struct ProviderMarkChip: View {
    let provider: UsageProvider
    var size: CGFloat = 24
    var plate = Color(nsColor: .quaternaryLabelColor)
    var keyline = Color(nsColor: .separatorColor)
    var keylineWidth: CGFloat = 0.5
    var ink = Color.primary
    @Environment(\.colorScheme) private var colorScheme

    /// Lower on dark plates, where a saturated hue at the same opacity turns muddy (an orange wash reads brown).
    nonisolated static func washOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.10 : 0.16
    }

    var body: some View {
        let tint = ProviderAccentPalette.color(for: self.provider)
        let shape = RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous)
        ZStack {
            shape.fill(self.plate)
            shape.fill(Color(red: tint.red, green: tint.green, blue: tint.blue)
                .opacity(Self.washOpacity(for: self.colorScheme)))
            shape.strokeBorder(self.keyline, lineWidth: self.keylineWidth)
            if let image = ProviderBrandIcon.image(for: self.provider, style: .brand) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(image.isTemplate ? .template : .original)
                    .scaledToFit()
                    .foregroundStyle(self.ink)
                    .padding(self.size * 0.2)
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}
