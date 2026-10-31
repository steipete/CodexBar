import CodexBarCore
import SwiftUI

@MainActor
struct MachineSpendDetail: View {
    @Bindable var settings: SettingsStore
    let store: UsageStore
    @Bindable var controller: SpendDashboardController

    var body: some View {
        DisclosureGroup(L("By machine"), isExpanded: self.$controller.machineExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(self.settings.selectableCostUsageHosts.enumerated()), id: \.element) { index, host in
                    Toggle(self.machineName(host, index: index), isOn: Binding(
                        get: { self.settings.costUsageHosts.contains(host) },
                        set: { selected in
                            self.settings.costUsageHosts = selected
                                ? self.settings.costUsageHosts + [host]
                                : self.settings.costUsageHosts.filter { $0 != host }
                        }))
                }
                HStack {
                    Text(L("Codex identified requests"))
                    if self.controller.selectedPeriod == .allTime { Text(L("Last %d days", 365)) }
                    Text(self.windowText)
                    Spacer()
                    if self.controller.machineRunning { ProgressView().controlSize(.small) }
                    Button(L("Refresh")) { self.run() }.disabled(self.controller.machineRunning)
                }
                .font(.caption)
                if let result = self.controller.machineResult {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow { Text(""); Text(L("Requests")); Text(L("Tokens")); Text(L("Cost")) }
                            .fontWeight(.medium)
                        ForEach(Array(result.reports.enumerated()), id: \.offset) { index, source in
                            self.row(
                                index == 0 ? L("This Mac") : self.machineName(source.host),
                                subtotal: source.subtotal,
                                hint: source.error,
                                partial: index == 0 && self.controller.machineLocalPartial)
                        }
                        Divider()
                        self.row(
                            L("Total"),
                            subtotal: result.subtotal ?? result.reports.first?.subtotal,
                            partial: result.partial || self.controller.machineLocalPartial)
                    }
                    Text(L("Shared requests count once.")).font(.caption).foregroundStyle(.secondary)
                    if self.controller.machineLocalPartial {
                        Text(L("Other Codex homes on this Mac aren't included.")).font(.caption)
                    }
                }
            }
            .padding(.top, 8)
        }
        .onChange(of: self.controller.machineExpanded, initial: true) { _, open in
            if open {
                self.run()
            } else {
                self.controller.cancelMachineSpend()
            }
        }
        .onChange(of: self.controller.selectedPeriod) { _, _ in
            self.controller.cancelMachineSpend()
            if self.controller.machineExpanded { self.run() }
        }
        .onChange(of: self.settings.costUsageHosts) { _, _ in self.controller.cancelMachineSpend() }
        .onDisappear { self.controller.machineExpanded = false; self.controller.cancelMachineSpend() }
    }

    private var windowText: String {
        guard let window = self.controller.machineWindow else { return "UTC" }
        var format = Date.FormatStyle.dateTime.year().month().day().locale(codexBarLocalizedLocale())
        format.timeZone = .gmt
        return "\(window.lowerBound.formatted(format)) – \(window.upperBound.formatted(format)) UTC"
    }

    private func machineName(_ host: String, index: Int? = nil) -> String {
        let index = index ?? self.settings.selectableCostUsageHosts.firstIndex(of: host) ?? 0
        return self.settings.hidePersonalInfo ? L("Machine %d", index + 1) : host
    }

    private func run() {
        let ambient = CodexHomeScope.ambientHomeURL(env: self.store.environmentBase).standardizedFileURL.path
        let partial = SpendDashboardSource.codexHomes(settings: self.settings, store: self.store)
            .contains { $0.homePath != ambient }
        self.controller.runMachineSpend(
            hosts: self.settings.costUsageHosts,
            // Provider-specific by design: only Codex history has identified requests to collect per machine.
            eligible: SpendDashboardSource.costCapableProviders(store: self.store).contains(.codex),
            localPartial: partial)
    }

    private func row(_ name: String, subtotal: CodexRequestSubtotal?, hint: String? = nil, partial: Bool) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if partial || subtotal?.partial == true || hint != nil {
                    Text(hint ?? L("codex_workspaces_partial_data")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(subtotal.map { codexBarLocalizedInteger($0.requestCount) } ?? "—")
            Text(subtotal.map { UsageFormatter.tokenCountString($0.totalTokens) } ?? "—")
            Text(subtotal.map { $0.costUSD.map { UsageFormatter.currencyString($0, currencyCode: "USD") }
                    ?? L("Unpriced")
            } ?? L("Unavailable"))
        }
    }
}
