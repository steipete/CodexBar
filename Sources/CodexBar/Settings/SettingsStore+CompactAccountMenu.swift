import CodexBarCore
import Foundation

extension SettingsStore {
    /// Local presentation state, keyed by source-issued identity rather than account labels or row order.
    var compactAccountExpandedIDs: Set<ProviderAccountIdentity> {
        get {
            let entries = self.userDefaults.array(forKey: "compactAccountExpandedIDs") ?? []
            return Set(entries.compactMap { entry in
                guard let entry = entry as? [String: String],
                      let source = entry["source"], !source.isEmpty,
                      let opaqueID = entry["opaqueID"], !opaqueID.isEmpty
                else { return nil }
                return ProviderAccountIdentity(source: source, opaqueID: opaqueID)
            })
        }
        set {
            let entries = newValue
                .sorted { ($0.source, $0.opaqueID) < ($1.source, $1.opaqueID) }
                .map { ["source": $0.source, "opaqueID": $0.opaqueID] }
            self.userDefaults.set(entries, forKey: "compactAccountExpandedIDs")
        }
    }
}
