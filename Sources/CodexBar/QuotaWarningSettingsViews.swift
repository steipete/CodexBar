import CodexBarCore
import SwiftUI

@MainActor
struct GlobalQuotaWarningSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuotaWarningThresholdField(
                title: "Warn at",
                subtitle: "Comma-separated remaining percentages. Applies to session and weekly windows unless " +
                    "a provider overrides them.",
                thresholds: { self.settings.quotaWarningThresholds },
                setThresholds: { self.settings.quotaWarningThresholds = $0 })

            Toggle(isOn: self.$settings.quotaWarningSoundEnabled) {
                Text("Play notification sound")
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.leading, 20)
    }
}

@MainActor
struct ProviderQuotaWarningSettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    var body: some View {
        ProviderSettingsSection(title: "Quota warnings") {
            Text("Uses the global quota warning settings unless a window is customized here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            self.windowRow(.session)
            self.windowRow(.weekly)
        }
    }

    private func windowRow(_ window: QuotaWarningWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) },
                set: { isOn in
                    if isOn {
                        self.settings.setQuotaWarningThresholds(
                            provider: self.provider,
                            window: window,
                            thresholds: self.settings.quotaWarningThresholds)
                    } else {
                        self.settings.setQuotaWarningThresholds(
                            provider: self.provider,
                            window: window,
                            thresholds: nil)
                    }
                })) {
                    Text("Customize \(window.displayName) thresholds")
                        .font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.checkbox)

            if self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) {
                QuotaWarningThresholdField(
                    title: "\(window.displayName.capitalized) warn at",
                    subtitle: "",
                    thresholds: {
                        self.settings.resolvedQuotaWarningThresholds(provider: self.provider, window: window)
                    },
                    setThresholds: {
                        self.settings.setQuotaWarningThresholds(
                            provider: self.provider,
                            window: window,
                            thresholds: $0)
                    })
                    .padding(.leading, 20)
            } else {
                Text("Inherited: \(Self.thresholdText(self.settings.quotaWarningThresholds))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private static func thresholdText(_ thresholds: [Int]) -> String {
        QuotaWarningThresholds.sanitized(thresholds).map { "\($0)%" }.joined(separator: ", ")
    }
}

@MainActor
private struct QuotaWarningThresholdField: View {
    let title: String
    let subtitle: String
    let thresholds: () -> [Int]
    let setThresholds: ([Int]) -> Void

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.title)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 110, alignment: .leading)

                TextField("50, 20", text: self.$text)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(maxWidth: 180)
                    .onSubmit { self.commit() }

                Button("Apply") { self.commit() }
                    .controlSize(.small)
            }

            if !self.subtitle.isEmpty {
                Text(self.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { self.text = Self.text(from: self.thresholds()) }
        .onChange(of: self.thresholds()) { _, value in
            self.text = Self.text(from: value)
        }
    }

    private func commit() {
        let parsed = self.text
            .split { !$0.isNumber }
            .compactMap { Int($0) }
        let sanitized = QuotaWarningThresholds.sanitized(parsed)
        self.text = Self.text(from: sanitized)
        self.setThresholds(sanitized)
    }

    private static func text(from thresholds: [Int]) -> String {
        QuotaWarningThresholds.sanitized(thresholds).map(String.init).joined(separator: ", ")
    }
}
