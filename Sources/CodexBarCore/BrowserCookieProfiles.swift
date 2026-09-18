#if os(macOS)
import Foundation
import SweetCookieKit

/// Merges primary/network stores within each browser profile before provider session validation.
enum BrowserCookieProfiles {
    struct Profile {
        let label: String
        let records: [BrowserCookieRecord]
    }

    static func merge(_ sources: [BrowserCookieStoreRecords]) -> [Profile] {
        Dictionary(grouping: sources, by: { $0.store.profile.id }).values
            .sorted { self.mergedLabel(for: $0) < self.mergedLabel(for: $1) }
            .map { Profile(label: self.mergedLabel(for: $0), records: self.mergeRecords($0)) }
    }

    private static func mergedLabel(for sources: [BrowserCookieStoreRecords]) -> String {
        guard let base = sources.map(\.label).min() else { return "Unknown" }
        if base.hasSuffix(" (Network)") {
            return String(base.dropLast(" (Network)".count))
        }
        return base
    }

    private static func mergeRecords(_ sources: [BrowserCookieStoreRecords]) -> [BrowserCookieRecord] {
        let sortedSources = sources.sorted { lhs, rhs in
            self.storePriority(lhs.store.kind) < self.storePriority(rhs.store.kind)
        }
        var mergedByKey: [String: BrowserCookieRecord] = [:]
        for source in sortedSources {
            for record in source.records {
                let key = self.recordKey(record)
                if let existing = mergedByKey[key] {
                    if self.shouldReplace(existing: existing, candidate: record) {
                        mergedByKey[key] = record
                    }
                } else {
                    mergedByKey[key] = record
                }
            }
        }
        return Array(mergedByKey.values)
    }

    private static func storePriority(_ kind: BrowserCookieStoreKind) -> Int {
        switch kind {
        case .network: 0
        case .primary: 1
        case .safari: 2
        }
    }

    private static func recordKey(_ record: BrowserCookieRecord) -> String {
        "\(record.name)|\(record.domain)|\(record.path)"
    }

    private static func shouldReplace(existing: BrowserCookieRecord, candidate: BrowserCookieRecord) -> Bool {
        switch (existing.expires, candidate.expires) {
        case let (lhs?, rhs?): rhs > lhs
        case (nil, .some): true
        case (.some, nil): false
        case (nil, nil): false
        }
    }
}
#endif
