import CodexBarCore
import SwiftUI

@MainActor
struct CodexManualSubscriptionSectionView: View {
    let snapshot: ProviderSubscriptionSnapshot?
    let onSave: (ProviderSubscriptionSnapshot) -> Void
    let onClear: () -> Void

    @State private var planName: String
    @State private var status: ProviderSubscriptionStatus
    @State private var hasRenewsAt: Bool
    @State private var renewsAt: Date
    @State private var hasExpiresAt: Bool
    @State private var expiresAt: Date
    @State private var notice: String?
    @State private var isExpanded = false

    init(
        snapshot: ProviderSubscriptionSnapshot?,
        onSave: @escaping (ProviderSubscriptionSnapshot) -> Void,
        onClear: @escaping () -> Void)
    {
        self.snapshot = snapshot
        self.onSave = onSave
        self.onClear = onClear

        let now = Date()
        let source = snapshot
        self._planName = State(initialValue: source?.planName ?? "")
        self._status = State(initialValue: source?.status ?? .active)
        self._hasRenewsAt = State(initialValue: source?.subscriptionRenewsAt != nil)
        self._renewsAt = State(initialValue: source?.subscriptionRenewsAt ?? now)
        self._hasExpiresAt = State(initialValue: source?.subscriptionExpiresAt != nil)
        self._expiresAt = State(initialValue: source?.subscriptionExpiresAt ?? now)
    }

    var body: some View {
        ProviderSettingsSection(title: "Subscription") {
            DisclosureGroup(isExpanded: self.$isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Plan name")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        TextField("Codex Plus (manual)", text: self.$planName)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                            .frame(maxWidth: 280)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Status")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        Picker("", selection: self.$status) {
                            ForEach(ProviderSubscriptionStatus.allCases, id: \.self) { value in
                                Text(Self.statusTitle(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Renewal date")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        Toggle("", isOn: self.$hasRenewsAt)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if self.hasRenewsAt {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Renews on")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                            Spacer(minLength: 0)
                            DatePicker("", selection: self.$renewsAt, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .environment(\.locale, codexBarLocalizedLocale())
                                .environment(\.calendar, Calendar(identifier: .gregorian))
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Expiry date")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        Toggle("", isOn: self.$hasExpiresAt)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if self.hasExpiresAt {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Expires on")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                            Spacer(minLength: 0)
                            DatePicker("", selection: self.$expiresAt, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .environment(\.locale, codexBarLocalizedLocale())
                                .environment(\.calendar, Calendar(identifier: .gregorian))
                        }
                    }

                    if let line = self.previewLine {
                        Text("Preview: Subscription: \(line)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let notice = self.notice, !notice.isEmpty {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Button("Save") {
                            self.saveSnapshot()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Clear") {
                            self.onClear()
                            self.notice = "Cleared manual subscription reminder."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Subscription reminder")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(self.summaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var previewLine: String? {
        let draft = self.makeSnapshotForSave(now: Date())
        return ProviderSubscriptionFormatter.menuLine(
            from: draft,
            now: Date(),
            locale: codexBarLocalizedLocale())
    }

    private var summaryText: String {
        if let line = self.previewLine {
            return line
        }
        return "Off"
    }

    private func saveSnapshot() {
        let snapshot = self.makeSnapshotForSave(now: Date())
        guard snapshot.hasDisplayableDate else {
            self.notice = "Enable renewal or expiry date before saving."
            return
        }
        self.onSave(snapshot)
        self.notice = "Saved to local config."
    }

    private func makeSnapshotForSave(now: Date) -> ProviderSubscriptionSnapshot {
        ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: self.planName,
            status: self.status,
            subscriptionRenewsAt: self.hasRenewsAt ? self.renewsAt : nil,
            subscriptionExpiresAt: self.hasExpiresAt ? self.expiresAt : nil,
            source: .manual,
            confidence: .manual,
            updatedAt: now)
    }

    private static func statusTitle(_ status: ProviderSubscriptionStatus) -> String {
        switch status {
        case .active: "Active"
        case .trialing: "Trialing"
        case .canceled: "Canceled"
        case .pastDue: "Past due"
        case .unknown: "Unknown"
        }
    }
}
