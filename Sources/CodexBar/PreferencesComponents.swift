import AppKit
import KeyboardShortcuts
import SwiftUI

/// Colored rounded-square symbol used for app panes in the settings sidebar,
/// mirroring the System Settings sidebar style.
struct SettingsIconChip: View {
    static let side: CGFloat = 20

    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: self.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.side, height: Self.side)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(
                        colors: [self.color.opacity(0.85), self.color],
                        startPoint: .top,
                        endPoint: .bottom)))
            .accessibilityHidden(true)
    }
}

/// Two-line label for grouped-form rows that genuinely need a supporting sentence.
struct SettingsRowLabel: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
struct OpenMenuShortcutRecorder: NSViewRepresentable {
    static let preferredWidth: CGFloat = 170

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        KeyboardShortcuts.RecorderCocoa(for: .openMenu)
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {
        nsView.shortcutName = .openMenu
    }

    func sizeThatFits(
        _: ProposedViewSize,
        nsView: KeyboardShortcuts.RecorderCocoa,
        context: Context)
        -> CGSize?
    {
        Self.fittedSize(intrinsicHeight: nsView.intrinsicContentSize.height)
    }

    static func fittedSize(intrinsicHeight: CGFloat) -> CGSize {
        CGSize(width: self.preferredWidth, height: intrinsicHeight)
    }
}

// MARK: - Legacy building blocks (Debug pane)

@MainActor
struct PreferenceToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var binding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5.4) {
            Toggle(isOn: self.$binding) {
                Text(self.title)
                    .font(.body)
            }
            .toggleStyle(.checkbox)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
struct SettingsSection<Content: View>: View {
    let title: String?
    let caption: String?
    let contentSpacing: CGFloat
    private let content: () -> Content

    init(
        title: String? = nil,
        caption: String? = nil,
        contentSpacing: CGFloat = 14,
        @ViewBuilder content: @escaping () -> Content)
    {
        self.title = title
        self.caption = caption
        self.contentSpacing = contentSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: self.contentSpacing) {
                self.content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
