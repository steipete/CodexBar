import CodexBarCore
import SwiftUI

struct ProviderAccountUsageOverview {
    struct Row: Identifiable {
        let id: String
        let title: String
        let isFollowed: Bool
        let isSystem: Bool
        let model: UsageMenuCardView.Model
        let usageItems: [ProviderUsageItemDescriptor]
        let updatedAt: Date?
        let sourceLabel: String?
        let error: String?
        let isRefreshing: Bool
    }

    let rows: [Row]
    let refreshLimit: Int
    let canRefresh: Bool
    let onRefresh: (Set<String>) -> Void

    var usageItems: [ProviderUsageItemDescriptor] {
        // Shared controls must keep a real quota visible regardless of account ordering.
        self.rows.flatMap(\.usageItems).reduce(into: []) { items, item in
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                if items[index].requiresOptionalUsage, !item.requiresOptionalUsage {
                    items[index] = item
                }
            } else {
                items.append(item)
            }
        }
    }
}

/// Account rows are inventory-owned; a failed or missing fetch must not remove an account.
@MainActor
struct ProviderAccountUsageOverviewView: View {
    let provider: UsageProvider
    let overview: ProviderAccountUsageOverview
    let isEnabled: Bool

    var body: some View {
        Section {
            Button(L("Refresh all accounts")) {
                self.overview.onRefresh(Set(self.overview.rows.map(\.id)))
            }
            .disabled(!self.overview.canRefresh)
        } header: {
            Text(L("All accounts"))
        } footer: {
            SettingsSectionFooter(self.overview.rows.count > self.overview.refreshLimit
                ? L(
                    "Refreshes up to %@ accounts at a time.",
                    String(self.overview.refreshLimit))
                : L("Each account has its own limits. Viewing usage does not switch accounts."))
        }

        ForEach(self.overview.rows) { row in
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                            .font(.headline)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            if row.isFollowed {
                                Text(L("CodexBar follows"))
                            }
                            if row.isSystem {
                                Text(L("System"))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        self.overview.onRefresh([row.id])
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Refresh"))
                    .disabled(!self.overview.canRefresh)
                    .accessibilityLabel(L("Refresh") + " " + row.title)
                }
                if let plan = row.model.planText, !plan.isEmpty {
                    LabeledContent(L("Plan"), value: plan)
                }
                LabeledContent(
                    L("Updated"),
                    value: row.isRefreshing ? L("Refreshing")
                        : row.updatedAt.map { UsageFormatter.updatedString(from: $0) } ?? L("Not fetched yet"))
                if let source = row.sourceLabel {
                    LabeledContent(L("Source"), value: source)
                }
                ProviderMetricsInlineView(
                    provider: self.provider,
                    model: row.model,
                    openAIWebDiagnostic: nil,
                    isEnabled: self.isEnabled,
                    isRefreshing: row.isRefreshing)
                if let error = row.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
