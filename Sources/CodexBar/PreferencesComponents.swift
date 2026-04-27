import AppKit
import SwiftUI

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
struct NotificationSettingsRow: View {
    let title: String
    let subtitle: String
    let hookPlaceholder: String
    let shortcutPlaceholder: String
    let globalEnabled: Bool
    let onSoundChange: @MainActor (NotificationSoundOption) -> Void
    @Binding var isEnabled: Bool
    @Binding var sound: NotificationSoundOption
    @Binding var hookCallURL: String
    @Binding var shortcutName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: self.$isEnabled) {
                Text(self.title)
                    .font(.body)
            }
            .toggleStyle(.checkbox)

            Text(self.subtitle)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sound")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Sound", selection: self.$sound) {
                        ForEach(NotificationSoundOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Hook URL")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField(self.hookPlaceholder, text: self.$hookCallURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Use {provider} anywhere in the URL to insert the provider name.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcut")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField(self.shortcutPlaceholder, text: self.$shortcutName)
                        .textFieldStyle(.roundedBorder)
                    Text("Shortcuts receive JSON input with a provider field, for example {\"provider\":\"Codex\"}.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!self.globalEnabled || !self.isEnabled)
        }
        .onChange(of: self.sound) { _, newValue in
            self.onSoundChange(newValue)
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
    }
}

@MainActor
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: self.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                Text(self.title)
                    .underline(self.hovering, color: .accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { self.hovering = $0 }
    }
}
