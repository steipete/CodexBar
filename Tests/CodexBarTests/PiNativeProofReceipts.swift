import Foundation
import XCTest
@testable import CodexBar
@testable import CodexBarCore

extension PiNativeProofSession {
    func record(archive: Bool = false) {
        let publication = store.spendDashboardPublication
        let model = controller.overviewSpendDashboardModel(providers: enabledProviders)
        let receipt: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "window": window?.windowNumber ?? 0,
            "action": lastAction, "actionNumber": actionNumber,
            "busy": busy, "failure": Self.jsonValue(failure),
            "syntheticOnly": true, "realWidgetKitCompositor": false,
            "piEnabled": piEnabled, "rootOffline": corpus.isOffline,
            "appended": corpus.hasAppended,
            "publicationRevision": publication.revision, "publicationGeneration": publication.generation,
            "isRefreshing": publication.isRefreshing,
            "tokens": model.groups.compactMap(\.totalTokens).reduce(0, +),
            "costUSD": model.groups.compactMap(\.totalCost).reduce(0, +),
            "sources": publication.sources.map {
                ["id": $0.id, "role": String(describing: $0.role), "state": String(describing: $0.state)]
            },
            "modelRows": model.groups.flatMap(\.providers).map {
                [
                    "id": $0.id,
                    "kind": $0.sourceKind.rawValue,
                    "tokens": Self.jsonValue($0.totalTokens),
                    "costUSD": Self.jsonValue($0.totalCost),
                    "coveredDayCount": $0.coveredDayCount,
                ] as [String: Any]
            },
            "snapshots": [UsageProvider.claude, .pi].map(self.snapshotReceipt),
            "widget": self.widgetReceipt(), "piCache": corpus.cacheEvidence(),
            "menuItems": openMenu?.items.compactMap { $0.representedObject as? String } ?? [],
            "recordedAt": Date().timeIntervalSince1970,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: corpus.output.appendingPathComponent("state.json"), options: .atomic)
            if archive {
                let name = "\(ProcessInfo.processInfo.processIdentifier)-\(actionNumber)-\(lastAction).json"
                let directory = corpus.output.appendingPathComponent("receipts", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        } catch {
            failure = "Receipt failed: \(error.localizedDescription)"
            XCTFail(failure ?? "Receipt failed")
        }
    }

    private func snapshotReceipt(_ provider: UsageProvider) -> [String: Any] {
        let regular = store.tokenSnapshotPublicationForCurrentProviderConfig(for: provider)
        let independent = store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: provider)
        func fields(_ publication: CurrentProviderConfigTokenPublication?) -> [String: Any] {
            guard let snapshot = publication?.snapshot else { return ["available": false] }
            return [
                "available": true, "tokens": Self.jsonValue(snapshot.last30DaysTokens),
                "costUSD": Self.jsonValue(snapshot.last30DaysCostUSD),
                "updatedAt": snapshot.updatedAt.timeIntervalSince1970,
                "coverageEstablished": snapshot.historyCoverageIsEstablished,
                "historyDays": snapshot.historyDays,
                "accounting": publication?.accounting.map { String(describing: $0) } ?? "none",
            ]
        }
        return ["provider": provider.rawValue, "regular": fields(regular), "dashboard": fields(independent)]
    }

    private func widgetReceipt() -> [[String: Any]] {
        widgetSnapshot?.entries.map { entry in
            [
                "provider": entry.provider.rawValue,
                "updatedAt": entry.updatedAt.timeIntervalSince1970,
                "tokenUpdatedAt": Self.jsonValue(entry.tokenUsage?.updatedAt?.timeIntervalSince1970),
                "tokens": Self.jsonValue(entry.tokenUsage?.last30DaysTokens),
                "costUSD": Self.jsonValue(entry.tokenUsage?.last30DaysCostUSD),
                "hasQuota": entry.primary != nil || entry.secondary != nil || entry.tertiary != nil,
                "usageRowCount": entry.usageRows?.count ?? 0,
            ]
        } ?? []
    }

    private static func jsonValue(_ value: (some Any)?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }
}
