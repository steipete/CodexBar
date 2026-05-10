import CodexBarCore
import SwiftUI

@MainActor
struct GlobalQuotaWarningSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.session) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.session, enabled: $0) }))
                {
                    Text("Session")
                        .font(.footnote)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.weekly) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.weekly, enabled: $0) }))
                {
                    Text("Weekly")
                        .font(.footnote)
                }
                .toggleStyle(.checkbox)
            }

            QuotaWarningThresholdField(
                title: "Warn at",
                subtitle: "Remaining percentages for session and weekly windows unless a provider overrides them.",
                thresholds: { self.settings.quotaWarningThresholds },
                setThresholds: { self.settings.quotaWarningThresholds = $0 })
                .disabled(!self.settings.quotaWarningWindowEnabled(.session) && !self.settings
                    .quotaWarningWindowEnabled(.weekly))
                .opacity(!self.settings.quotaWarningWindowEnabled(.session) && !self.settings
                    .quotaWarningWindowEnabled(.weekly) ? 0.55 : 1)

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
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: self.settings.quotaWarningThresholds,
                            enabled: self.settings.quotaWarningWindowEnabled(window))
                    } else {
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: nil,
                            enabled: nil)
                    }
                })) {
                    Text("Customize \(window.displayName) thresholds")
                        .font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.checkbox)

            if self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) {
                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningEnabled(provider: self.provider, window: window) },
                    set: {
                        self.settings.setQuotaWarningWindowEnabled(
                            provider: self.provider,
                            window: window,
                            enabled: $0)
                    })) {
                        Text("Enable \(window.displayName) warnings")
                            .font(.footnote)
                    }
                    .toggleStyle(.checkbox)
                        .padding(.leading, 20)

                if self.settings.quotaWarningEnabled(provider: self.provider, window: window) {
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
                    Text("Off")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            } else {
                Text("Inherited: " + Self.thresholdText(
                    self.settings.quotaWarningThresholds,
                    enabled: self.settings.quotaWarningWindowEnabled(window)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private static func thresholdText(_ thresholds: [Int], enabled: Bool) -> String {
        guard enabled else { return "Off" }
        let text = QuotaWarningThresholds.active(thresholds).map { "\($0)%" }.joined(separator: ", ")
        return text.isEmpty ? "depleted only" : text
    }
}

@MainActor
private struct QuotaWarningThresholdField: View {
    let title: String
    let subtitle: String
    let thresholds: () -> [Int]
    let setThresholds: ([Int]) -> Void

    @State private var upperText: String = ""
    @State private var lowerText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.title)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 110, alignment: .leading)

                Text("Upper")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("50", text: self.$upperText)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(width: 56)
                    .onChange(of: self.upperText) { _, value in
                        self.upperText = Self.filteredIntegerText(value)
                    }
                    .onSubmit { self.commit() }

                Text("Lower")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("20", text: self.$lowerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(width: 56)
                    .onChange(of: self.lowerText) { _, value in
                        self.lowerText = Self.filteredIntegerText(value)
                    }
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
        .onAppear { self.updateText(from: self.thresholds()) }
        .onChange(of: self.thresholds()) { _, value in
            self.updateText(from: value)
        }
    }

    private func commit() {
        let sanitized = QuotaWarningThresholds.resolved(
            upper: Self.integer(from: self.upperText),
            lower: Self.integer(from: self.lowerText))
        self.updateText(from: sanitized)
        self.setThresholds(sanitized)
    }

    private func updateText(from thresholds: [Int]) {
        let pair = Self.pair(from: thresholds)
        self.upperText = pair.upper.map(String.init) ?? ""
        self.lowerText = pair.lower.map(String.init) ?? ""
    }

    private static func pair(from thresholds: [Int]) -> (upper: Int?, lower: Int?) {
        let sanitized = QuotaWarningThresholds.sanitized(thresholds)
        return (sanitized.first, sanitized.dropFirst().first)
    }

    private static func integer(from text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        return Int(text)
    }

    private static func filteredIntegerText(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(2))
    }
}
