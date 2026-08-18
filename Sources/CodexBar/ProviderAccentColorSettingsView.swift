import AppKit
import CodexBarCore
import SwiftUI

/// Per-provider accent color override.
///
/// The hex field is the source of truth and the color well writes into it, so a user can paste an
/// exact brand hex or pick visually. Reset appears only when an override exists. Descriptors hold the
/// shipped color as a compile-time constant, so a reset restores it and can never lose it.
@MainActor
struct ProviderAccentColorSettingsView: View {
    private static let swatchSize: CGFloat = 18
    private static let swatchCornerRadius: CGFloat = 4
    private static let hexFieldWidth: CGFloat = 92

    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    @State private var hexText: String
    @FocusState private var isHexFieldFocused: Bool

    init(provider: UsageProvider, settings: SettingsStore) {
        self.provider = provider
        self.settings = settings
        // Seed here rather than in onAppear, so the field always carries a value on first render.
        self._hexText = State(initialValue: settings.accentColor(for: provider).hexString)
    }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                self.swatch

                TextField(L("provider_accent_color_title"), text: self.$hexText)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: Self.hexFieldWidth)
                    .focused(self.$isHexFieldFocused)
                    .onSubmit { self.commitHexText() }
                    .accessibilityLabel(L("provider_accent_color_hex_label"))

                ColorPicker(
                    L("provider_accent_color_title"),
                    selection: self.colorBinding,
                    supportsOpacity: false)
                    .labelsHidden()

                Spacer(minLength: 0)

                if self.hasOverride {
                    Button(L("provider_accent_color_reset")) { self.reset() }
                        .controlSize(.small)
                }
            }
            .listRowSeparator(.hidden)
        } header: {
            Text(L("provider_accent_color_title"))
        } footer: {
            SettingsSectionFooter(L("provider_accent_color_footer"))
        }
        .background(FocusResigningBackground())
        .onAppear { self.syncHexText() }
        .onChange(of: self.isHexFieldFocused) { _, isFocused in
            if !isFocused {
                self.commitHexText()
            }
        }
        .onChange(of: self.settings.configRevision) { _, _ in
            // An external config edit or an inbound sync can move the color while this pane is open.
            // Never fight the user mid-edit.
            guard !self.isHexFieldFocused else { return }
            self.syncHexText()
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: Self.swatchCornerRadius, style: .continuous)
            .fill(Self.swiftUIColor(self.resolvedColor))
            .frame(width: Self.swatchSize, height: Self.swatchSize)
            .overlay(
                RoundedRectangle(cornerRadius: Self.swatchCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15)))
            .accessibilityHidden(true)
    }

    private var hasOverride: Bool {
        self.settings.accentColorOverride(for: self.provider) != nil
    }

    private var resolvedColor: ProviderColor {
        self.settings.accentColor(for: self.provider)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Self.swiftUIColor(self.resolvedColor) },
            set: { newValue in
                guard let color = Self.providerColor(from: newValue) else { return }
                self.settings.setAccentColorOverride(color, for: self.provider)
                self.hexText = color.hexString
            })
    }

    private func syncHexText() {
        self.hexText = self.resolvedColor.hexString
    }

    /// Applies the typed value, or restores the displayed one when the text does not parse.
    private func commitHexText() {
        guard let color = ProviderColor(hexString: self.hexText) else {
            self.syncHexText()
            return
        }
        self.settings.setAccentColorOverride(color, for: self.provider)
        self.hexText = color.hexString
    }

    private func reset() {
        self.settings.setAccentColorOverride(nil, for: self.provider)
        self.syncHexText()
    }

    private static func swiftUIColor(_ color: ProviderColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }

    /// The color well can hand back a wide-gamut color, so pin it to sRGB before storing the hex.
    private static func providerColor(from color: Color) -> ProviderColor? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return ProviderColor(
            red: Double(srgb.redComponent),
            green: Double(srgb.greenComponent),
            blue: Double(srgb.blueComponent))
    }
}
