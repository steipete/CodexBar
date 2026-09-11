import CodexBarCore
import SwiftUI

/// One read-only account row in the claude-swap settings section.
struct ClaudeSwapSectionAccountRow: Identifiable, Equatable {
    let id: ProviderAccountIdentity
    let label: String
    let isActive: Bool
    /// Sentinel note (expired credentials, deferred polling, …) instead of usable usage.
    let note: String?
}

/// Everything the claude-swap settings section renders, projected as plain values so the
/// grouping rules can be tested without building SwiftUI views.
@MainActor
struct ClaudeSwapSectionState: Equatable {
    let isEnabled: Bool
    /// The path stored in config. Empty when the user has not chosen one.
    let configuredPath: String
    /// The path the adapter actually runs; empty when nothing usable was found.
    let resolvedPath: String
    let defaultPath: String
    let detectedVersion: String?
    let lastRefreshAt: Date?
    let lastError: String?
    let accounts: [ClaudeSwapSectionAccountRow]

    /// True when the adapter is running from the default location rather than a chosen path.
    var usesDefaultPath: Bool {
        self.configuredPath.isEmpty && !self.resolvedPath.isEmpty
    }

    /// True when the adapter is on but has nowhere to run from — the only case that still asks
    /// the user to fill in a path.
    var needsPath: Bool {
        self.isEnabled && self.resolvedPath.isEmpty
    }

    /// The default location in the tilde form the field shows as its placeholder. The resolver
    /// works with the expanded path; this is display only.
    static let defaultPathPlaceholder = "~/.local/bin/cswap"

    /// One line under the field describing adapter state. It deliberately does not repeat the
    /// path: an empty field already shows the default as its placeholder, and a filled one shows
    /// the chosen path, so printing it again here just crowded the row.
    var statusText: String? {
        guard self.isEnabled else { return nil }
        if self.needsPath {
            return "No cswap executable at \(Self.defaultPathPlaceholder)."
        }
        var parts: [String] = []
        if let version = self.detectedVersion {
            parts.append("claude-swap \(version)")
        }
        if let lastError {
            parts.append(lastError)
        } else if let lastRefreshAt {
            let count = self.accounts.count
            parts.append("\(count == 1 ? "1 account" : "\(count) accounts"), "
                + "updated \(lastRefreshAt.relativeDescription())")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

/// Groups the claude-swap toggle, executable path, adapter status and discovered accounts into a
/// single settings section, rendered through the same supplementary-content slot the Codex
/// accounts section uses.
struct ClaudeSwapSectionView: View {
    let state: ClaudeSwapSectionState
    @Binding var isEnabled: Bool
    @Binding var executablePath: String
    @Binding var showsSingleAccountCard: Bool

    var body: some View {
        Section {
            Toggle(isOn: self.$isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Read accounts from claude-swap"))
                    Text(L(
                        "Shows usage and lets you switch accounts through cswap. "
                            + "Credentials stay managed by claude-swap; CodexBar never reads them."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if self.state.isEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L("Executable"))
                            .font(.subheadline.weight(.semibold))
                            .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                        // Match PreferencesProviderSettingsRows: an EmptyView label plus a
                        // prompt keeps the placeholder inside the field. Passing the string as
                        // TextField's title renders it as a leading label instead.
                        TextField(
                            text: self.$executablePath,
                            prompt: Text(ClaudeSwapSectionState.defaultPathPlaceholder))
                        {
                            EmptyView()
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }

                    if let status = self.state.statusText {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(self.state.needsPath || self.state.lastError != nil
                                ? AnyShapeStyle(.orange)
                                : AnyShapeStyle(.secondary))
                    }
                }

                Toggle(isOn: self.$showsSingleAccountCard) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Show account card when only one account is available"))
                        Text(L("Prefer claude-swap over the ambient Claude account presentation."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !self.state.accounts.isEmpty {
                    ForEach(self.state.accounts) { account in
                        self.accountRow(account)
                    }
                }
            }
        } header: {
            Text(L("claude-swap accounts"))
        }
    }

    private func accountRow(_ account: ClaudeSwapSectionAccountRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(account.label)
                .font(.subheadline)
            if account.isActive {
                Text(L("Active"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
            if let note = account.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
