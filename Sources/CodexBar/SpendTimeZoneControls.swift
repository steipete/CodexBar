import CodexBarCore
import SwiftUI

@MainActor
struct SpendTimeZoneControls: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Statistics time zone"))
                .font(.subheadline.weight(.medium))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    self.picker
                    self.currentZoneButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    self.picker
                    self.currentZoneButton
                }
            }
            Text(L("Daily usage uses a fixed time zone. Changing it may move usage to a different day."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        Picker(L("Statistics time zone"), selection: self.timeZoneBinding) {
            ForEach(self.timeZoneIdentifiers, id: \.self) { identifier in
                Text(verbatim: identifier).tag(identifier)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 260)
        .help(self.selectedIdentifier)
        .accessibilityIdentifier("spend-time-zone-picker")
    }

    private var currentZoneButton: some View {
        Button(L("Use Mac's current time zone")) {
            self.useCurrentTimeZone()
        }
        .fixedSize()
        .help(TimeZone.current.identifier)
        .accessibilityIdentifier("spend-use-current-time-zone")
    }

    var selectedIdentifier: String {
        let storedIdentifier = self.settings.costUsageBucketTimeZoneIdentifier
        return CostUsageBucketTimeZone.isValidIdentifier(storedIdentifier)
            ? storedIdentifier
            : self.settings.costUsageBucketCalendar.timeZone.identifier
    }

    var timeZoneIdentifiers: [String] {
        // Include stored aliases and fixed offsets, which may be absent from Foundation's catalog.
        Array(Set(TimeZone.knownTimeZoneIdentifiers + [self.selectedIdentifier, TimeZone.current.identifier, "UTC"]))
            .sorted()
    }

    var timeZoneBinding: Binding<String> {
        Binding(
            get: { self.selectedIdentifier },
            set: { self.settings.costUsageBucketTimeZoneIdentifier = $0 })
    }

    func useCurrentTimeZone(_ timeZone: TimeZone = .current) {
        self.settings.costUsageBucketTimeZoneIdentifier = timeZone.identifier
    }
}
