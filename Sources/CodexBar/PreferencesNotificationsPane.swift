import SwiftUI

@MainActor
struct NotificationsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(
                    title: "Notifications",
                    caption: "CodexBar can show local macOS notifications, call webhook-style URLs, and run Apple " +
                        "Shortcuts when important events happen.")
                {
                    PreferenceToggleRow(
                        title: "Enable notifications",
                        subtitle: "Master switch for all notification events. Per-event settings stay saved.",
                        binding: self.$settings.notificationsEnabled)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sound volume")
                                    .font(.body)
                                Text("Global level for custom notification sounds and sound previews.")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(self.volumeLabel)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: self.$settings.notificationVolume, in: 0...1)
                    }

                    Text("Local banners and sounds still follow the macOS notification permission for CodexBar.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(
                    title: "Events",
                    caption: "Each event can use its own sound, webhook URL, and Shortcut name.")
                {
                    ForEach(Array(AppNotificationEvent.allCases.enumerated()), id: \.element.id) { index, event in
                        NotificationSettingsRow(
                            title: event.settingsTitle,
                            subtitle: event.settingsSubtitle,
                            hookPlaceholder: event.hookPlaceholder,
                            shortcutPlaceholder: event.shortcutPlaceholder,
                            globalEnabled: self.settings.notificationsEnabled,
                            onSoundChange: self.previewSound,
                            isEnabled: self.binding(for: event, field: \.enabled),
                            sound: self.binding(for: event, field: \.sound),
                            hookCallURL: self.binding(for: event, field: \.hookCallURL),
                            shortcutName: self.binding(for: event, field: \.shortcutName))

                        if index < AppNotificationEvent.allCases.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func binding<Value>(
        for event: AppNotificationEvent,
        field: WritableKeyPath<NotificationDeliverySettings, Value>) -> Binding<Value>
    {
        Binding(
            get: { self.settings.notificationSettings(for: event)[keyPath: field] },
            set: { newValue in
                var settings = self.settings.notificationSettings(for: event)
                settings[keyPath: field] = newValue
                self.settings.setNotificationSettings(settings, for: event)
            })
    }

    private func previewSound(_ sound: NotificationSoundOption) {
        _ = NotificationSoundPlayer.playPreview(sound, volume: self.settings.notificationVolume)
    }

    private var volumeLabel: String {
        "\(Int((self.settings.notificationVolume * 100).rounded()))%"
    }
}
