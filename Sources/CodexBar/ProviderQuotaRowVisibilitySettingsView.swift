import CodexBarCore
import SwiftUI

/// Per-row visibility toggles for the extra quota lanes a provider reports (Claude's model-scoped
/// weekly limits and Daily Routines, Antigravity's per-model quotas, and so on).
///
/// The rows are discovered from the latest snapshot rather than hard-coded, because which lanes
/// exist depends on the account's plan and changes over time. Rows the user already hid are still
/// listed while the provider keeps reporting them, so a hidden row can be brought back.
@MainActor
struct ProviderQuotaRowVisibilitySettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.id) { row in
                    Toggle(isOn: self.binding(for: row.id)) {
                        Text(L(row.title))
                            .font(.subheadline)
                    }
                    .toggleStyle(.checkbox)
                    .listRowSeparator(.hidden)
                }

                if !self.settings.hiddenQuotaRowIDs(for: self.provider).isEmpty {
                    Button(L("quota_rows_show_all")) {
                        self.settings.showAllQuotaRows(for: self.provider)
                    }
                    .buttonStyle(.link)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(L("quota_rows_title"))
            } footer: {
                SettingsSectionFooter(L("quota_rows_footer"))
            }
            .background(FocusResigningBackground())
        }
    }

    /// Rows the provider currently reports, plus any still-hidden row it stopped reporting so the
    /// user can always undo a hide from this pane.
    private var rows: [NamedRateWindow] {
        let reported = self.store.snapshot(for: self.provider.instanceID)?.extraRateWindows ?? []
        var seen = Set(reported.map(\.id))
        var rows = reported
        for hiddenID in self.settings.hiddenQuotaRowIDs(for: self.provider).sorted()
            where seen.insert(hiddenID).inserted
        {
            rows.append(NamedRateWindow(
                id: hiddenID,
                title: hiddenID,
                window: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil)))
        }
        return rows
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.settings.isQuotaRowVisible(id, for: self.provider) },
            set: { self.settings.setQuotaRow(id, visible: $0, for: self.provider) })
    }
}
