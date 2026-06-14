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
        let prefersExpiry = source?.subscriptionExpiresAt != nil
        self._planName = State(initialValue: source?.planName ?? "")
        self._status = State(initialValue: source?.status ?? .active)
        self._hasRenewsAt = State(initialValue: source?.subscriptionRenewsAt != nil && !prefersExpiry)
        self._renewsAt = State(initialValue: source?.subscriptionRenewsAt ?? now)
        self._hasExpiresAt = State(initialValue: source?.subscriptionExpiresAt != nil)
        self._expiresAt = State(initialValue: source?.subscriptionExpiresAt ?? now)
        self._isExpanded = State(initialValue: source != nil)
    }

    var body: some View {
        ProviderSettingsSection(title: L("Manual reminder")) {
            DisclosureGroup(isExpanded: self.$isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L(
                        """
                        Use this local-only fallback when CodexBar cannot read your Codex renewal \
                        or expiry automatically.
                        """))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L(
                        """
                        This does not sync with Codex and only affects menu display and reminder \
                        notifications on this Mac.
                        """))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L("Plan name (optional)"))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        TextField(L("Codex Plus"), text: self.$planName)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                            .frame(maxWidth: 280)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L("Renewal date"))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        Toggle("", isOn: self.renewalBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if self.hasRenewsAt {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(L("Renews on"))
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

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(L("Status"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                            Spacer(minLength: 0)
                            Picker("", selection: self.$status) {
                                Text(Self.statusTitle(.active)).tag(ProviderSubscriptionStatus.active)
                                Text(Self.statusTitle(.trialing)).tag(ProviderSubscriptionStatus.trialing)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L("Expiry date"))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)
                        Spacer(minLength: 0)
                        Toggle("", isOn: self.expiryBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if self.hasExpiresAt {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(L("Expires on"))
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
                        Text(L("Menu preview: %@", L("Subscription: %@", line)))
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
                        Button(L("Save")) {
                            self.saveSnapshot()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(L("Clear")) {
                            self.clearSnapshot()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L("Manual subscription reminder"))
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
            locale: codexBarLocalizedLocale(),
            strings: localizedProviderSubscriptionFormatterStrings())
    }

    private var summaryText: String {
        if let line = self.previewLine {
            return line
        }
        return L("Off")
    }

    private var renewalBinding: Binding<Bool> {
        Binding(
            get: { self.hasRenewsAt },
            set: { isEnabled in
                self.hasRenewsAt = isEnabled
                if isEnabled {
                    self.hasExpiresAt = false
                    if self.status != .active, self.status != .trialing {
                        self.status = .active
                    }
                }
            })
    }

    private var expiryBinding: Binding<Bool> {
        Binding(
            get: { self.hasExpiresAt },
            set: { isEnabled in
                self.hasExpiresAt = isEnabled
                if isEnabled {
                    self.hasRenewsAt = false
                    self.status = Self.effectiveStatusForSave(hasExpiresAt: true, status: self.status)
                }
            })
    }

    private func saveSnapshot() {
        let snapshot = self.makeSnapshotForSave(now: Date())
        guard snapshot.hasDisplayableDate else {
            self.notice = L("Turn on a renewal or expiry date before saving.")
            return
        }
        self.onSave(snapshot)
        self.notice = L("Saved manual reminder on this Mac.")
    }

    private func clearSnapshot() {
        let now = Date()
        self.planName = ""
        self.status = .active
        self.hasRenewsAt = false
        self.renewsAt = now
        self.hasExpiresAt = false
        self.expiresAt = now
        self.onClear()
        self.notice = L("Cleared manual reminder.")
    }

    private func makeSnapshotForSave(now: Date) -> ProviderSubscriptionSnapshot {
        let effectiveStatus = Self.effectiveStatusForSave(hasExpiresAt: self.hasExpiresAt, status: self.status)

        return ProviderSubscriptionSnapshot(
            provider: .codex,
            planName: self.planName,
            status: effectiveStatus,
            subscriptionRenewsAt: self.hasRenewsAt ? self.renewsAt : nil,
            subscriptionExpiresAt: self.hasExpiresAt ? self.expiresAt : nil,
            source: .manual,
            confidence: .manual,
            updatedAt: now)
    }

    static func effectiveStatusForSave(
        hasExpiresAt: Bool,
        status: ProviderSubscriptionStatus) -> ProviderSubscriptionStatus
    {
        if hasExpiresAt {
            return .canceled
        }
        return status
    }

    private static func statusTitle(_ status: ProviderSubscriptionStatus) -> String {
        switch status {
        case .active: L("Active")
        case .trialing: L("Trialing")
        case .canceled: L("Canceled")
        case .pastDue: L("Past due")
        case .unknown: L("Unknown")
        }
    }
}
