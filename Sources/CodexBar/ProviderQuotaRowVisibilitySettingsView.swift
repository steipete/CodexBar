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

                if QuotaRowVisibilityListing.hasIndependentlyHiddenRows(
                    listed: rows,
                    hiddenIDs: self.settings.hiddenQuotaRowIDs(for: self.provider))
                {
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

    /// Rows the provider currently reports that family gates still allow, plus any still-hidden row
    /// it stopped reporting so the user can undo a hide. Family-gated extras (Spark, Daily Routines,
    /// optional credits, Copilot extras) stay off this list — the family toggle owns them.
    private var rows: [NamedRateWindow] {
        QuotaRowVisibilityListing.rows(
            reported: self.store.snapshot(for: self.provider.instanceID)?.extraRateWindows ?? [],
            hiddenIDs: self.settings.hiddenQuotaRowIDs(for: self.provider),
            gates: self.settings.quotaRowFamilyGates(for: self.provider))
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.settings.isQuotaRowVisible(id, for: self.provider) },
            set: { self.settings.setQuotaRow(id, visible: $0, for: self.provider) })
    }
}
