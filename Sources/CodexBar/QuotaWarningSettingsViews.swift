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
                    Text(L("quota_warning_session_capitalized"))
                        .font(.footnote)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.weekly) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.weekly, enabled: $0) }))
                {
                    Text(L("quota_warning_weekly_capitalized"))
                        .font(.footnote)
                }
                .toggleStyle(.checkbox)
            }

            self.windowThresholdField(.session)
            self.windowThresholdField(.weekly)

            Toggle(isOn: self.$settings.quotaWarningSoundEnabled) {
                Text(L("quota_warning_sound"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: self.$settings.quotaWarningOnScreenAlertEnabled) {
                Text(L("quota_warning_onscreen_alert"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)
        }
        .padding(.leading, 20)
    }

    private func windowThresholdField(_ window: QuotaWarningWindow) -> some View {
        QuotaWarningThresholdField(
            title: String(format: L("quota_warning_window_warn_at"), window.localizedCapitalizedDisplayName),
            subtitle: L("quota_warning_global_threshold_subtitle"),
            thresholds: { self.settings.quotaWarningThresholds(window) },
            setThresholds: { self.settings.setQuotaWarningThresholds(window, thresholds: $0) })
            .disabled(!self.settings.quotaWarningWindowEnabled(window))
            .opacity(!self.settings.quotaWarningWindowEnabled(window) ? 0.55 : 1)
    }
}

@MainActor
struct ProviderQuotaWarningSettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    var body: some View {
        Section {
            self.windowRow(.session)
            self.windowRow(.weekly)
        } header: {
            Text(L("quota_warnings_title"))
        } footer: {
            Text(L("quota_warning_provider_inherits"))
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
                            thresholds: self.settings.quotaWarningThresholds(window),
                            enabled: self.settings.quotaWarningWindowEnabled(window))
                    } else {
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: nil,
                            enabled: nil)
                    }
                })) {
                    Text(String(format: L("quota_warning_customize_thresholds"), window.localizedDisplayName))
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
                        Text(String(format: L("quota_warning_enable_warnings"), window.localizedDisplayName))
                            .font(.footnote)
                    }
                    .toggleStyle(.checkbox)
                        .padding(.leading, 20)

                if self.settings.quotaWarningEnabled(provider: self.provider, window: window) {
                    QuotaWarningThresholdField(
                        title: String(
                            format: L("quota_warning_window_warn_at"),
                            window.localizedCapitalizedDisplayName),
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
                    Text(L("quota_warning_off"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            } else {
                Text(String(format: L("quota_warning_inherited"), Self.thresholdText(
                    self.settings.quotaWarningThresholds(window),
                    enabled: self.settings.quotaWarningWindowEnabled(window))))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private static func thresholdText(_ thresholds: [Int], enabled: Bool) -> String {
        guard enabled else { return L("quota_warning_off") }
        let text = QuotaWarningThresholds.active(thresholds).map { "\($0)%" }.joined(separator: ", ")
        return text.isEmpty ? L("quota_warning_depleted_only") : text
    }
}

extension QuotaWarningWindow {
    fileprivate var localizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session")
        case .weekly: L("quota_warning_weekly")
        }
    }

    fileprivate var localizedCapitalizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session_capitalized")
        case .weekly: L("quota_warning_weekly_capitalized")
        }
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

                Text(L("quota_warning_upper"))
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

                Text(L("quota_warning_lower"))
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

                Button(L("apply")) { self.commit() }
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
