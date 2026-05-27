import CodexBarCore
import SwiftUI

struct OnboardingProviderMiniIcon: View {
    let provider: UsageProvider
    let size: CGFloat

    var body: some View {
        if let image = ProviderBrandIcon.image(for: self.provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.95))
                .padding(self.size * self.paddingScale)
                .frame(width: self.size, height: self.size)
                .background(self.background)
                .clipShape(RoundedRectangle(cornerRadius: self.size * 0.26, style: .continuous))
        } else {
            Text(String(Self.displayName(self.provider).prefix(1)))
                .font(.system(size: self.size * 0.48, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: self.size, height: self.size)
                .background(self.background)
                .clipShape(RoundedRectangle(cornerRadius: self.size * 0.26, style: .continuous))
        }
    }

    private var background: Color {
        self.color
    }

    private var paddingScale: CGFloat {
        switch self.provider {
        case .cursor:
            0.22
        case .claude:
            0.12
        case .opencode:
            0.18
        default:
            0.18
        }
    }

    private var color: Color {
        ProviderDescriptorRegistry.descriptor(for: self.provider).branding.color.swiftUIColor
    }

    private static func displayName(_ provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
    }
}

struct OnboardingCodexBarAppIcon: View {
    let size: CGFloat

    var body: some View {
        if let image = ProviderBrandIcon.appIconImage() {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: self.size, height: self.size)
                .clipShape(RoundedRectangle(cornerRadius: self.size * 0.23, style: .continuous))
        } else {
            OnboardingProviderMiniIcon(provider: .codex, size: self.size)
        }
    }
}

struct OnboardingUsageGlyph: View {
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule()
                .fill(self.color)
                .frame(width: 22, height: 6)
            Capsule()
                .fill(self.color.opacity(0.78))
                .frame(width: 19, height: 5)
        }
        .frame(width: 24, height: 18, alignment: .leading)
    }
}

struct OnboardingActionButtonStyle: ButtonStyle {
    enum Kind {
        case finish
        case permission
        case primary
        case secondary
    }

    @Environment(\.isEnabled) private var isEnabled
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        OnboardingActionButtonBody(
            configuration: configuration,
            isEnabled: self.isEnabled,
            kind: self.kind)
    }
}

private struct OnboardingActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isEnabled: Bool
    let kind: OnboardingActionButtonStyle.Kind
    @State private var isHovered = false

    var body: some View {
        self.configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(self.foreground)
            .padding(.horizontal, self.horizontalPadding)
            .frame(height: 40)
            .background {
                self.background(configuration: self.configuration)
            }
            .overlay {
                self.stroke
            }
            .opacity(self.isEnabled ? 1 : 0.42)
            .scaleEffect(self.configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.16), value: self.isHovered)
            .onHover { self.isHovered = $0 }
    }

    private var foreground: Color {
        switch self.kind {
        case .finish, .permission, .primary:
            .white
        case .secondary:
            OnboardingPalette.secondaryText
        }
    }

    private var horizontalPadding: CGFloat {
        switch self.kind {
        case .finish, .permission:
            24
        case .primary:
            20
        case .secondary:
            12
        }
    }

    @ViewBuilder
    private func background(configuration: ButtonStyle.Configuration) -> some View {
        switch self.kind {
        case .finish, .permission:
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.11 : self.isHovered ? 0.095 : 0.075))
                Capsule()
                    .fill(OnboardingPalette.finishGradient
                        .opacity(configuration.isPressed ? 0.22 : self.isHovered ? 0.34 : 0.27))
                Circle()
                    .fill(OnboardingPalette.brandBlue
                        .opacity(configuration.isPressed ? 0.42 : self.isHovered ? 0.72 : 0.58))
                    .frame(width: 34, height: 34)
                    .blur(radius: self.isHovered ? 16 : 14)
                    .offset(x: 10)
            }
            .clipShape(Capsule())
            .shadow(
                color: OnboardingPalette.brandBlue.opacity(self.isHovered ? 0.34 : 0.24),
                radius: self.isHovered ? 18 : 14,
                x: 0,
                y: 0)
        case .primary:
            if configuration.isPressed {
                Capsule()
                    .fill(Color.white.opacity(0.1))
            } else if self.isHovered {
                Capsule()
                    .fill(Color.white.opacity(0.18))
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.13))
            }
        case .secondary:
            if configuration.isPressed {
                Capsule()
                    .fill(Color.white.opacity(0.08))
            } else if self.isHovered {
                Capsule()
                    .fill(Color.white.opacity(0.055))
            } else {
                Capsule()
                    .fill(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var stroke: some View {
        switch self.kind {
        case .finish, .permission:
            Capsule()
                .stroke(OnboardingPalette.finishGradient, lineWidth: self.isHovered ? 1.35 : 1)
        case .primary:
            Capsule()
                .stroke(Color.white.opacity(self.isHovered ? 0.28 : 0.15), lineWidth: 1)
        case .secondary:
            Capsule()
                .stroke(Color.white.opacity(self.isHovered ? 0.08 : 0), lineWidth: 1)
        }
    }
}

struct OnboardingIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        OnboardingIconButtonBody(configuration: configuration, isEnabled: self.isEnabled)
    }
}

private struct OnboardingIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isEnabled: Bool
    @State private var isHovered = false

    var body: some View {
        self.configuration.label
            .foregroundStyle(.white.opacity(self.isEnabled ? 0.78 : 0.28))
            .background {
                Circle()
                    .fill(self.configuration.isPressed ? Color.white.opacity(0.14) : self.isHovered ? Color.white
                        .opacity(0.11) : Color.white.opacity(0.075))
            }
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(self.isHovered ? 0.15 : 0.08), lineWidth: 1)
            }
            .scaleEffect(self.configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: self.isHovered)
            .onHover { self.isHovered = $0 }
    }
}

extension ProviderColor {
    var swiftUIColor: Color {
        Color(red: self.red, green: self.green, blue: self.blue)
    }
}
